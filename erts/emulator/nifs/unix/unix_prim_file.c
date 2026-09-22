/*
 * %CopyrightBegin%
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Copyright Ericsson 2017-2022. All Rights Reserved.
 * Copyright Ericsson AB 2017-2025. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * %CopyrightEnd%
 */

#include "erl_nif.h"
#include "config.h"
#include "sys.h"

#ifdef VALGRIND
#  include <valgrind/memcheck.h>
#endif

#include "prim_file_nif.h"

#if defined(__APPLE__) && defined(__MACH__) && !defined(__DARWIN__)
#define __DARWIN__ 1
#endif

#if defined(__DARWIN__) || defined(HAVE_LINUX_FALLOC_H) || defined(HAVE_POSIX_FALLOCATE)
#include <fcntl.h>
#endif

#ifdef HAVE_LINUX_FALLOC_H
#include <linux/falloc.h>
#endif

#include <utime.h>
#include <limits.h>

/* Old platforms might not define PATH_MAX. */
#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

#define FALLBACK_RW_LENGTH ((1ull << 31) - 1)

/* Macros for testing file types. */
#ifdef NO_UMASK
#define FILE_MODE 0644
#define DIR_MODE  0755
#else
#define FILE_MODE 0666
#define DIR_MODE  0777
#endif

/* Old platforms might not have IOV_MAX defined. */
#if !defined(IOV_MAX) && defined(UIO_MAXIOV)
#define IOV_MAX UIO_MAXIOV
#elif !defined(IOV_MAX)
#define IOV_MAX 16
#endif

typedef struct {
    efile_data_t common;
    int fd;
} efile_unix_t;

static int has_invalid_null_termination(const ErlNifBinary *path) {
    const char *null_pos, *end_pos;

    null_pos = memchr(path->data, '\0', path->size);
    end_pos = (const char*)&path->data[path->size] - 1;

    if(null_pos == NULL) {
        return 1;
    }

    /* prim_file:internal_name2native sometimes feeds us data that is "doubly"
     * NUL-terminated, so we'll accept any number of trailing NULs so long as
     * they aren't interrupted by anything else. */
    while(null_pos < end_pos && (*null_pos) == '\0') {
        null_pos++;
    }

    return null_pos != end_pos;
}

posix_errno_t efile_marshal_path(ErlNifEnv *env, ERL_NIF_TERM path, efile_path_t *result) {
    if(!enif_inspect_binary(env, path, result)) {
        return EINVAL;
    }

    if(has_invalid_null_termination(result)) {
        return EINVAL;
    }

    return 0;
}

posix_errno_t efile_marshal_name(ErlNifEnv *env, ERL_NIF_TERM name, efile_path_t *result) {
    /* A path is not expanded on this platform, so a name needs no different
     * treatment than a path. */
    return efile_marshal_path(env, name, result);
}

ERL_NIF_TERM efile_get_handle(ErlNifEnv *env, efile_data_t *d) {
    efile_unix_t *u = (efile_unix_t*)d;
    int fd = u->fd;
    ERL_NIF_TERM handle;
    unsigned char *bits;

    bits = enif_make_new_binary(env, sizeof(fd), &handle);
    memcpy(bits, &fd, sizeof(fd));

    return handle;
}

posix_errno_t efile_dup_handle(ErlNifEnv *env, efile_data_t *d, ErlNifEvent *handle) {
    efile_unix_t *u = (efile_unix_t*)d;
    int fd;

    if ((fd = dup(u->fd)) < 0)
        return errno;

    *handle = fd;
    return 0;
}

static int open_file_is_dir(const efile_path_t *path, int fd) {
    struct stat file_info;
    int error;

#ifndef HAVE_FSTAT
    if(path == NULL) {
        return 0;
    }

    error = stat((const char*)path->data, &file_info);
    (void)fd;
#else
    error = fstat(fd, &file_info);
    (void)path;
#endif

    /* Assume not a directory on error. */
    return error == 0 && S_ISDIR(file_info.st_mode);
}

static int get_flags(enum efile_modes_t modes) {
    int flags = 0;
    if(modes & EFILE_MODE_READ && !(modes & EFILE_MODE_WRITE)) {
        flags |= O_RDONLY;
    } else if(modes & EFILE_MODE_WRITE && !(modes & EFILE_MODE_READ)) {
        flags |= O_TRUNC | O_WRONLY | O_CREAT;
    } else if(modes & EFILE_MODE_READ_WRITE) {
        flags |= O_RDWR | O_CREAT;
    } else {
        return EINVAL;
    }

    if(modes & EFILE_MODE_APPEND) {
        flags &= ~O_TRUNC;
        flags |= O_APPEND;
    }

    if(modes & EFILE_MODE_EXCLUSIVE) {
        flags |= O_EXCL;
    }

    if(modes & EFILE_MODE_SYNC) {
#ifndef O_SYNC
        return ENOTSUP;
#else
        flags |= O_SYNC;
#endif
    }
    return flags;
}

/* Returns the open(2) flags and the creation mode for the given modes. */
static void get_open_flags(enum efile_modes_t modes, int *flags, int *mode) {
    (*flags) = get_flags(modes);

    if(modes & EFILE_MODE_DIRECTORY) {
        (*mode) = DIR_MODE;
#ifdef O_DIRECTORY
        (*flags) |= O_DIRECTORY;
#endif
    } else {
        (*mode) = FILE_MODE;
    }
}

/* Wraps a descriptor that open(2) or openat(2) returned in a resource. The
 * path is NULL for a name in a directory. */
static posix_errno_t build_open_resource(const efile_path_t *path, int fd,
        enum efile_modes_t modes, ErlNifResourceType *nif_type,
        efile_data_t **d) {
    if(fd != -1) {
        efile_unix_t *u;

#ifndef O_DIRECTORY
        /* On platforms without O_DIRECTORY support, ensure that using the
         * directory flag to open a file fails. */
        if(!(modes & EFILE_MODE_SKIP_TYPE_CHECK) &&
           (modes & EFILE_MODE_DIRECTORY) && !open_file_is_dir(path, fd)) {
            close(fd);
            return ENOTDIR;
        }
#endif

        /* open() works on directories without the O_DIRECTORY flag but for
         * consistency across platforms we require that the user has requested
         * directory mode. */
        if(!(modes & EFILE_MODE_SKIP_TYPE_CHECK) &&
           !(modes & EFILE_MODE_DIRECTORY) && open_file_is_dir(path, fd)) {
            close(fd);
            return EISDIR;
        }

        u = (efile_unix_t*)enif_alloc_resource(nif_type, sizeof(efile_unix_t));
        u->fd = fd;

        EFILE_INIT_RESOURCE(&u->common, modes);
        (*d) = &u->common;

        return 0;
    }

    (*d) = NULL;
    return errno;
}

static posix_errno_t open_path(const efile_path_t *path,
        enum efile_modes_t modes, ErlNifResourceType *nif_type,
        efile_data_t **d) {
    int mode, flags, fd;

    get_open_flags(modes, &flags, &mode);

    do {
        fd = open((const char*)path->data, flags, mode);
    } while(fd == -1 && errno == EINTR);

    return build_open_resource(path, fd, modes, nif_type, d);
}

static posix_errno_t open_at(efile_data_t *dir, const efile_path_t *path,
        enum efile_modes_t modes, ErlNifResourceType *nif_type,
        efile_data_t **d) {
#ifndef HAVE_OPENAT
    (void)dir;
    (void)path;
    (void)modes;
    (void)nif_type;

    (*d) = NULL;
    return ENOTSUP;
#else
    efile_unix_t *u = (efile_unix_t*)dir;
    int mode, flags, fd;

    get_open_flags(modes, &flags, &mode);

    /* openat(2) resolves the name against the open directory, so the caller
     * cannot be tricked into opening a file outside the directory it holds.
     * The name itself is not checked here. A name that contains ".." or that
     * starts with a separator still escapes the directory. */
    do {
        fd = openat(u->fd, (const char*)path->data, flags, mode);
    } while(fd == -1 && errno == EINTR);

    return build_open_resource(NULL, fd, modes, nif_type, d);
#endif
}

/* What an operation calls the system with for a target that is not a path:
 * the directory the last component of the name belongs to, and that
 * component. */
struct efile_resolved {
    char component[PATH_MAX];
    int parent_fd;

    /* Whether resolved_release closes the descriptor. */
    int owned;

    /* Whether the call follows a last component that is a link. */
    int follow_last;
};

/* What the operation does with the name. */
enum efile_resolve_flags_t {
    /* The operation follows a last component that is a link. */
    EFILE_RESOLVE_FOLLOW_LAST = (1 << 0),

    /* The operation can act on the directory the name resolves to, as
     * list_dir can. A delete or a rename cannot. */
    EFILE_RESOLVE_SELF_OK = (1 << 1)
};

static void resolved_release(struct efile_resolved *resolved) {
    if(resolved->owned) {
        close(resolved->parent_fd);
    }
}

#if defined(HAVE_OPENAT) && defined(HAVE_READLINKAT)
/* The most links that may be followed while one name is resolved. The limit
 * stops a cycle of links from resolving forever. */
#define EFILE_MAX_LINK_DEPTH 32

/* The most components a name may have. A name that is longer than this is
 * refused rather than resolved, so the walk cannot be made to run for an
 * unreasonable time. */
#define EFILE_MAX_WALK_STEPS 4096

/* One position in a walk from a root directory. "fd" is the directory the
 * next component is resolved against. The root itself is never closed. */
struct root_walk {
    int root_fd;
    int fd;
    int links_followed;
};

static void walk_init(struct root_walk *walk, int root_fd) {
    walk->root_fd = root_fd;
    walk->fd = root_fd;
    walk->links_followed = 0;
}

static void walk_close(struct root_walk *walk) {
    if(walk->fd != walk->root_fd && walk->fd != -1) {
        close(walk->fd);
    }

    walk->fd = walk->root_fd;
}

static void walk_enter(struct root_walk *walk, int fd) {
    walk_close(walk);
    walk->fd = fd;
}

/* Reads the length of the component that starts at "name", and where the next
 * component starts. Repeated separators are skipped. */
static size_t component_length(const char *name, size_t *next) {
    size_t length = 0;

    while(name[length] != '\0' && name[length] != '/') {
        length++;
    }

    *next = length;

    while(name[*next] == '/') {
        (*next)++;
    }

    return length;
}

static int component_is(const char *name, size_t length, const char *against) {
    return strlen(against) == length && memcmp(name, against, length) == 0;
}

/* Removes the ".." at "up_start" and the component before it, so that the
 * walk can start again from the root. Asking the system for ".." would race
 * with a rename of the directory the walk is in. A "." before the ".." does
 * not count. EXDEV when nothing is left to remove: the name leaves the root. */
static posix_errno_t remove_parent_reference(char *name, size_t up_start,
        size_t up_next) {
    size_t previous, scan;
    int found;

    found = 0;
    previous = 0;
    scan = 0;

    while(scan < up_start) {
        size_t length, next;

        length = component_length(&name[scan], &next);

        if(length > 0 && !component_is(&name[scan], length, ".")) {
            previous = scan;
            found = 1;
        }

        scan += next;
    }

    if(!found) {
        return EXDEV;
    }

    sys_memmove(&name[previous], &name[up_start + up_next],
                strlen(&name[up_start + up_next]) + 1);

    return 0;
}

/* Puts the target of a link in place of the component at "offset", ahead of
 * what follows that component. An absolute target starts again at the root,
 * as an absolute name does. */
static posix_errno_t splice_link_target(struct root_walk *walk, char *name,
        size_t name_size, size_t offset, size_t next, const char *target) {
    char rest[PATH_MAX];
    size_t target_length, rest_length;

    if(target[0] == '/') {
        walk_close(walk);

        while(target[0] == '/') {
            target++;
        }
    }

    target_length = strlen(target);
    rest_length = strlen(&name[offset + next]);

    if(offset + target_length + 1 + rest_length >= name_size) {
        return ENAMETOOLONG;
    }

    sys_memcpy(rest, &name[offset + next], rest_length + 1);
    sys_memcpy(&name[offset], target, target_length);

    if(rest_length > 0) {
        name[offset + target_length] = '/';
        sys_memcpy(&name[offset + target_length + 1], rest, rest_length + 1);
    } else {
        name[offset + target_length] = '\0';
    }

    return 0;
}

/* Resolves every component of "name" but the last one, so that the caller is
 * left holding the directory the last component belongs to. The name is
 * changed as links are followed, so it has to be a buffer of "name_size".
 *
 * On success "last" points at the last component and "last_length" holds its
 * length. A name whose last component is "." or ".." has no last component of
 * its own. The walk resolves such a name in full and sets "last_length" to 0.
 *
 * The last component is always a plain name. It holds no separator. It is
 * never "." or "..", because the walk resolves both of those itself. The
 * caller can therefore give it to an *at call. The system cannot reach a file
 * outside the directory the walk ended on. */
static posix_errno_t walk_to_last(struct root_walk *walk, char *name,
        size_t name_size, const char **last, size_t *last_length) {
    size_t offset = 0;
    int steps = 0;

    for(;;) {
        char component[PATH_MAX];
        size_t length, next;
        int fd;

        while(name[offset] == '/') {
            offset++;
        }

        if(steps++ > EFILE_MAX_WALK_STEPS) {
            return ENAMETOOLONG;
        }

        length = component_length(&name[offset], &next);

        if(length == 0) {
            /* The name ended, so the walk is at the directory that holds it
             * and there is no component left to open. */
            *last = &name[offset];
            *last_length = 0;

            return 0;
        }

        if(component_is(&name[offset], length, ".")) {
            offset += next;
            continue;
        }

        if(component_is(&name[offset], length, "..")) {
            posix_errno_t posix_errno;

            posix_errno = remove_parent_reference(name, offset, next);

            if(posix_errno != 0) {
                return posix_errno;
            }

            walk_close(walk);
            offset = 0;
            continue;
        }

        if(name[offset + next] == '\0' && next == length) {
            /* This is the last component, and the caller opens it. The
             * checks above consume "." and "..", and a name that holds a
             * separator does not reach here. This component is therefore a
             * plain name. */
            *last = &name[offset];
            *last_length = length;

            return 0;
        }

        if(length >= sizeof(component)) {
            return ENAMETOOLONG;
        }

        sys_memcpy(component, &name[offset], length);
        component[length] = '\0';

        /* A component in the middle of the name has to be a directory, so it
         * is opened as one. The link flag makes a symbolic link fail rather
         * than be followed, so that a link is seen here and followed only as
         * far as the root. */
        do {
            fd = openat(walk->fd, component, O_RDONLY | O_NOFOLLOW
#ifdef O_DIRECTORY
                        | O_DIRECTORY
#endif
                        );
        } while(fd == -1 && errno == EINTR);

        if(fd == -1) {
            posix_errno_t saved_errno = errno;
            char target[PATH_MAX];
            ssize_t target_length;

            /* ELOOP means the component is a symbolic link, because the link
             * flag stopped the system from following it. ENOTDIR means the
             * same on the systems that report it that way. */
            if(saved_errno != ELOOP && saved_errno != EMLINK
               && saved_errno != ENOTDIR) {
                return saved_errno;
            }

            target_length = readlinkat(walk->fd, component, target,
                                       sizeof(target) - 1);

            if(target_length < 0) {
                /* Not a link after all, so report what the open reported. */
                return saved_errno;
            }

            if(walk->links_followed++ > EFILE_MAX_LINK_DEPTH) {
                return ELOOP;
            }

            target[target_length] = '\0';

            /* The link is followed by putting its target in place of the
             * component, so that the rest of the name is resolved from
             * wherever the target leads. */
            saved_errno = splice_link_target(walk, name, name_size, offset,
                                             next, target);

            if(saved_errno != 0) {
                return saved_errno;
            }

            continue;
        }

        walk_enter(walk, fd);
        offset += next;
    }
}

/* Resolves a name in a root to the directory that holds its last component,
 * and that component. The rules are those of walk_to_last, so the name cannot
 * reach a file outside the root.
 *
 * With EFILE_RESOLVE_FOLLOW_LAST a last component that is a symbolic link is
 * followed as well, from the directory that holds the link. The component the
 * caller is left with is then never a link. The call the caller makes must
 * not follow a link either way, because a link that appears after the walk
 * would lead out of the root.
 *
 * A name that resolves to a directory the walk holds has no last component of
 * its own. With EFILE_RESOLVE_SELF_OK the caller is given "." against that
 * directory. Without it the caller is told EISDIR, because it would act on
 * the name itself.
 *
 * The walk hands the directory it holds to the caller, which closes it
 * through resolved_release. The root itself is never closed. */
static posix_errno_t resolve_in_root(efile_data_t *root,
        const efile_path_t *path, int flags, struct efile_resolved *resolved) {
    efile_unix_t *u = (efile_unix_t*)root;
    posix_errno_t posix_errno;
    struct root_walk walk;
    char name[PATH_MAX];
    const char *last = NULL;
    size_t last_length = 0;

    if(path->size > sizeof(name)) {
        return ENAMETOOLONG;
    }

    sys_memcpy(name, path->data, path->size);
    name[sizeof(name) - 1] = '\0';

    walk_init(&walk, u->fd);

    /* Each turn resolves the name to the directory that holds its last
     * component. A last component that is a symbolic link starts another turn
     * with the target of the link, which is resolved from the directory that
     * holds the link. */
    for(;;) {
        char target[PATH_MAX];
        ssize_t target_length;

        posix_errno = walk_to_last(&walk, name, sizeof(name), &last,
                                   &last_length);

        if(posix_errno != 0) {
            walk_close(&walk);
            return posix_errno;
        }

        if(last_length >= sizeof(resolved->component)) {
            walk_close(&walk);
            return ENAMETOOLONG;
        }

        sys_memcpy(resolved->component, last, last_length);
        resolved->component[last_length] = '\0';

        if(last_length == 0 || !(flags & EFILE_RESOLVE_FOLLOW_LAST)) {
            break;
        }

        target_length = readlinkat(walk.fd, resolved->component, target,
                                   sizeof(target) - 1);

        if(target_length < 0) {
            /* Not a link, or nothing there. The operation reports what it
             * finds. */
            break;
        }

        if(walk.links_followed++ > EFILE_MAX_LINK_DEPTH) {
            walk_close(&walk);
            return ELOOP;
        }

        target[target_length] = '\0';
        sys_memcpy(name, target, target_length + 1);
    }

    if(resolved->component[0] == '\0') {
        if(!(flags & EFILE_RESOLVE_SELF_OK)) {
            walk_close(&walk);
            return EISDIR;
        }

        resolved->component[0] = '.';
        resolved->component[1] = '\0';
    }

    /* The walk holds the directory. It gives the directory to the caller
     * rather than closing it. */
    resolved->parent_fd = walk.fd;
    resolved->owned = (walk.fd != walk.root_fd);
    resolved->follow_last = 0;

    return 0;
}
#endif

static posix_errno_t open_in_root(efile_data_t *root,
        const efile_path_t *path, enum efile_modes_t modes,
        ErlNifResourceType *nif_type, efile_data_t **d) {
#if !defined(HAVE_OPENAT) || !defined(HAVE_READLINKAT)
    (void)root;
    (void)path;
    (void)modes;
    (void)nif_type;

    (*d) = NULL;
    return ENOTSUP;
#else
    struct efile_resolved resolved;
    posix_errno_t posix_errno;
    int mode, flags, fd;

    posix_errno = resolve_in_root(root, path,
        EFILE_RESOLVE_FOLLOW_LAST | EFILE_RESOLVE_SELF_OK, &resolved);

    if(posix_errno != 0) {
        (*d) = NULL;
        return posix_errno;
    }

    get_open_flags(modes, &flags, &mode);

    /* The walk followed every link, so the component is not a link. The link
     * flag makes sure that one that appeared since fails rather than reaches
     * a file outside the root. */
    do {
        fd = openat(resolved.parent_fd, resolved.component,
                    flags | O_NOFOLLOW, mode);
    } while(fd == -1 && errno == EINTR);

    posix_errno = build_open_resource(NULL, fd, modes, nif_type, d);

    resolved_release(&resolved);

    return posix_errno;
#endif
}

/* Fills in a name that the system resolves against the directory as it is.
 * The name is not checked, so a name that holds ".." still reaches a file
 * outside the directory. The system checks the name on the call itself, so
 * the flags only say how the call is made. */
static posix_errno_t resolve_name(const efile_path_t *name, int parent_fd,
        int flags, struct efile_resolved *resolved) {
    size_t length = strlen((const char*)name->data);

    if(length >= sizeof(resolved->component)) {
        return ENAMETOOLONG;
    }

    sys_memcpy(resolved->component, name->data, length + 1);

    resolved->parent_fd = parent_fd;
    resolved->owned = 0;
    resolved->follow_last = !!(flags & EFILE_RESOLVE_FOLLOW_LAST);

    return 0;
}

/* Turns a target that is not a path into what the operation calls the system
 * with. The caller gives the result to resolved_release when it is done. An
 * operation with an "_at" variant takes a name in an open directory and a
 * name in a root through that variant, and this function tells them apart.
 *
 * A name in an open directory is used as it is, against that directory. A
 * name in a root is walked, and the caller is given the directory that holds
 * the last component, and that component, which is then always a plain
 * name. */
static posix_errno_t resolve_target(const efile_target_t *target, int flags,
        struct efile_resolved *resolved) {
    efile_unix_t *u = (efile_unix_t*)target->dir;

    if(target->kind == EFILE_TARGET_AT) {
        return resolve_name(&target->name, u->fd, flags, resolved);
    }

#if defined(HAVE_OPENAT) && defined(HAVE_READLINKAT)
    return resolve_in_root(target->dir, &target->name, flags, resolved);
#else
    (void)resolved;

    return ENOTSUP;
#endif
}

/* As resolve_target, but this function answers a target that is a path with
 * the working directory and the path itself. An operation that takes two
 * names can take a path for one of them and a name in a directory for the
 * other. */
static posix_errno_t resolve_either(const efile_target_t *target, int flags,
        struct efile_resolved *resolved) {
    if(target->kind == EFILE_TARGET_PATH) {
        return resolve_name(&target->name, AT_FDCWD, flags, resolved);
    }

    return resolve_target(target, flags, resolved);
}

posix_errno_t efile_open(const efile_target_t *target, enum efile_modes_t modes,
        ErlNifResourceType *nif_type, efile_data_t **d) {
    switch(target->kind) {
    case EFILE_TARGET_PATH:
        return open_path(&target->name, modes, nif_type, d);
    case EFILE_TARGET_AT:
        return open_at(target->dir, &target->name, modes, nif_type, d);
    case EFILE_TARGET_ROOT:
        return open_in_root(target->dir, &target->name, modes, nif_type, d);
    default:
        (*d) = NULL;
        return EINVAL;
    }
}

posix_errno_t efile_from_fd(int fd,
                            ErlNifResourceType *nif_type,
                            efile_data_t **d) {
    if (fcntl(fd, F_GETFL) != -1 || errno != EBADF) {
        efile_unix_t *u;

        u = (efile_unix_t*)enif_alloc_resource(nif_type, sizeof(efile_unix_t));
        u->fd = fd;

        EFILE_INIT_RESOURCE(&u->common, EFILE_MODE_FROM_ALREADY_OPEN_FD);
        (*d) = &u->common;

        return 0;
    }
    (*d) = NULL;
    return errno;
}

posix_errno_t efile_dup(efile_data_t *d, ErlNifResourceType *nif_type,
        efile_data_t **copy) {
    efile_unix_t *u = (efile_unix_t*)d;
    efile_unix_t *c;
    int fd;

    do {
        fd = dup(u->fd);
    } while(fd == -1 && errno == EINTR);

    if(fd == -1) {
        (*copy) = NULL;
        return errno;
    }

    c = (efile_unix_t*)enif_alloc_resource(nif_type, sizeof(efile_unix_t));
    c->fd = fd;

    EFILE_INIT_RESOURCE(&c->common, d->modes & ~EFILE_MODE_FROM_ALREADY_OPEN_FD);
    (*copy) = &c->common;

    return 0;
}

int efile_close(efile_data_t *d, posix_errno_t *error) {
    efile_unix_t *u = (efile_unix_t*)d;
    int fd;

    ASSERT(enif_thread_type() == ERL_NIF_THR_DIRTY_IO_SCHEDULER);
    ASSERT(erts_atomic32_read_nob(&d->state) == EFILE_STATE_CLOSED);
    ASSERT(u->fd != -1);

    fd = u->fd;
    u->fd = -1;

    enif_release_resource(d);

    /* close(2) either always closes (*BSD, Linux) or leaves the fd in an
     * undefined state (POSIX 2008, Solaris), so we must not retry on EINTR. */

    if(close(fd) < 0) {
        *error = errno;
        return 0;
    }

    return 1;
}

static void shift_iov(SysIOVec **iov, int *iovlen, ssize_t shift) {
    SysIOVec *head_vec = (*iov);

    ASSERT(shift >= 0);

    while(shift > 0) {
        ASSERT(head_vec < &(*iov)[*iovlen]);

        if(shift < head_vec->iov_len) {
            head_vec->iov_base = (char*)head_vec->iov_base + shift;
            head_vec->iov_len -= shift;
            break;
        } else {
            shift -= head_vec->iov_len;
            head_vec++;
        }
    }

    (*iovlen) -= head_vec - (*iov);
    (*iov) = head_vec;
}

Sint64 efile_readv(efile_data_t *d, SysIOVec *iov, int iovlen) {
    efile_unix_t *u = (efile_unix_t*)d;

    Sint64 bytes_read;
    ssize_t result;

    bytes_read = 0;

    do {
        int use_fallback = 0;

        if(iovlen < 1) {
            result = 0;
            break;
        }

        /* writev(2) implies readv(2) */
#ifdef HAVE_WRITEV
        result = readv(u->fd, iov, MIN(IOV_MAX, iovlen));

        /* Fall back to using read(2) if readv(2) reports that the combined
         * size of iov is greater than SSIZE_T_MAX. */
        use_fallback = (result < 0 && errno == EINVAL);
#else
        use_fallback = 1;
#endif

        if(use_fallback) {
            result = read(u->fd, iov->iov_base, iov->iov_len);

            /* Some OSs (e.g. macOS) does not allow reads greater than 2 GB,
               so if we get EINVAL in the fallback, we try with a smaller length */
            if (result < 0 && errno == EINVAL && iov->iov_len > FALLBACK_RW_LENGTH)
                result = read(u->fd, iov->iov_base, FALLBACK_RW_LENGTH);
        }

        if(result > 0) {
            shift_iov(&iov, &iovlen, result);
            bytes_read += result;
        }
    } while(result > 0 || (result < 0 && errno == EINTR));

    u->common.posix_errno = errno;

    if(result == 0 && bytes_read > 0) {
        return bytes_read;
    }

    return result;
}

Sint64 efile_writev(efile_data_t *d, SysIOVec *iov, int iovlen) {
    efile_unix_t *u = (efile_unix_t*)d;

    Sint64 bytes_written;
    ssize_t result;

    bytes_written = 0;

    do {
        int use_fallback = 0;

        if(iovlen < 1) {
            result = 0;
            break;
        }

#ifdef HAVE_WRITEV
        result = writev(u->fd, iov, MIN(IOV_MAX, iovlen));

        /* Fall back to using write(2) if writev(2) reports that the combined
         * size of iov is greater than SSIZE_T_MAX. */
        use_fallback = (result < 0 && errno == EINVAL);
#else
        use_fallback = 1;
#endif

        if(use_fallback) {
            result = write(u->fd, iov->iov_base, iov->iov_len);

            /* Some OSs (e.g. macOS) does not allow writes greater than 2 GB,
               so if we get EINVAL in the fallback, we try with a smaller length */
            if (result < 0 && errno == EINVAL && iov->iov_len > FALLBACK_RW_LENGTH)
                result = write(u->fd, iov->iov_base, FALLBACK_RW_LENGTH);
        }

        if(result > 0) {
            shift_iov(&iov, &iovlen, result);
            bytes_written += result;
        }
    } while(result > 0 || (result < 0 && errno == EINTR));

    u->common.posix_errno = errno;

    if(result == 0 && bytes_written > 0) {
        return bytes_written;
    }

    return result;
}

Sint64 efile_preadv(efile_data_t *d, Sint64 offset, SysIOVec *iov, int iovlen) {
    efile_unix_t *u = (efile_unix_t*)d;

    Uint64 bytes_read;
    Sint64 result;

#if !defined(HAVE_PREADV) && !defined(HAVE_PREAD)
    /* This function is documented as leaving the file position undefined, but
     * the old driver always reset it so there's probably code in the wild that
     * relies on this behavior. */
    off_t original_position = lseek(u->fd, 0, SEEK_CUR);

    if(original_position < 0 || lseek(u->fd, offset, SEEK_SET) < 0) {
        u->common.posix_errno = errno;
        return -1;
    }
#endif

    bytes_read = 0;

    do {
        if(iovlen < 1) {
            result = 0;
            break;
        }

#if defined(HAVE_PREADV)
        result = preadv(u->fd, iov, MIN(IOV_MAX, iovlen), offset);
#elif defined(HAVE_PREAD)
        result = pread(u->fd, iov->iov_base, iov->iov_len, offset);
#else
        result = read(u->fd, iov->iov_base, iov->iov_len);
#endif

        if(result > 0) {
            shift_iov(&iov, &iovlen, result);
            bytes_read += result;
            offset += result;
        }
    } while(result > 0 || (result < 0 && errno == EINTR));

    u->common.posix_errno = errno;

#if !defined(HAVE_PREADV) && !defined(HAVE_PREAD)
    if(result >= 0) {
        if(lseek(u->fd, original_position, SEEK_SET) < 0) {
            u->common.posix_errno = errno;
            return -1;
        }
    }
#endif

    if(result == 0 && bytes_read > 0) {
        return bytes_read;
    }

    return result;
}

Sint64 efile_pwritev(efile_data_t *d, Sint64 offset, SysIOVec *iov, int iovlen) {
    efile_unix_t *u = (efile_unix_t*)d;

    Sint64 bytes_written;
    ssize_t result;

#if !defined(HAVE_PWRITEV) && !defined(HAVE_PWRITE)
    off_t original_position = lseek(u->fd, 0, SEEK_CUR);

    if(original_position < 0 || lseek(u->fd, offset, SEEK_SET) < 0) {
        u->common.posix_errno = errno;
        return -1;
    }
#endif

    bytes_written = 0;

    do {
        if(iovlen < 1) {
            result = 0;
            break;
        }

#if defined(HAVE_PWRITEV)
        result = pwritev(u->fd, iov, MIN(IOV_MAX, iovlen), offset);
#elif defined(HAVE_PWRITE)
        result = pwrite(u->fd, iov->iov_base, iov->iov_len, offset);
#else
        result = write(u->fd, iov->iov_base, iov->iov_len);
#endif

        if(result > 0) {
            shift_iov(&iov, &iovlen, result);
            bytes_written += result;
            offset += result;
        }
    } while(result > 0 || (result < 0 && errno == EINTR));

    u->common.posix_errno = errno;

#if !defined(HAVE_PWRITEV) && !defined(HAVE_PWRITE)
    if(result >= 0) {
        if(lseek(u->fd, original_position, SEEK_SET) < 0) {
            u->common.posix_errno = errno;
            return -1;
        }
    }
#endif

    if(result == 0 && bytes_written > 0) {
        return bytes_written;
    }

    return result;
}

int efile_seek(efile_data_t *d, enum efile_seek_t seek, Sint64 offset, Sint64 *new_position) {
    efile_unix_t *u = (efile_unix_t*)d;
    off_t result;
    int whence;

    switch(seek) {
        case EFILE_SEEK_BOF: whence = SEEK_SET; break;
        case EFILE_SEEK_CUR: whence = SEEK_CUR; break;
        case EFILE_SEEK_EOF: whence = SEEK_END; break;
        default: ERTS_INTERNAL_ERROR("Invalid seek parameter");
    }

    result = lseek(u->fd, offset, whence);

    /*
     * The man page for lseek (on SunOs 5) says:
     *
     * "if fildes is a remote file descriptor and offset is negative, lseek()
     * returns the file pointer even if it is negative."
     */
    if(result < 0 && errno == 0) {
        errno = EINVAL;
    }

    if(result < 0) {
        u->common.posix_errno = errno;
        return 0;
    }

    (*new_position) = result;

    return 1;
}

int efile_sync(efile_data_t *d, int data_only) {
    efile_unix_t *u = (efile_unix_t*)d;

#if defined(HAVE_FDATASYNC) && !defined(__DARWIN__)
    if(data_only) {
        if(fdatasync(u->fd) < 0) {
            u->common.posix_errno = errno;
            return 0;
        }

        return 1;
    }
#endif

#if defined(__DARWIN__) && defined(F_BARRIERFSYNC)
    if(fcntl(u->fd, F_BARRIERFSYNC) < 0) {
#elif defined(__DARWIN__) && defined(F_FULLFSYNC)
    if(fcntl(u->fd, F_FULLFSYNC) < 0) {
#else
    if(fsync(u->fd) < 0) {
#endif
        u->common.posix_errno = errno;
        return 0;
    }

    return 1;
}

int efile_advise(efile_data_t *d, Sint64 offset, Sint64 length, enum efile_advise_t advise) {
#ifdef HAVE_POSIX_FADVISE
    efile_unix_t *u = (efile_unix_t*)d;
    int p_advise;

    switch(advise) {
        case EFILE_ADVISE_NORMAL: p_advise = POSIX_FADV_NORMAL; break;
        case EFILE_ADVISE_RANDOM: p_advise = POSIX_FADV_RANDOM; break;
        case EFILE_ADVISE_SEQUENTIAL: p_advise = POSIX_FADV_SEQUENTIAL; break;
        case EFILE_ADVISE_WILL_NEED: p_advise = POSIX_FADV_WILLNEED; break;
        case EFILE_ADVISE_DONT_NEED: p_advise = POSIX_FADV_DONTNEED; break;
        case EFILE_ADVISE_NO_REUSE: p_advise = POSIX_FADV_NOREUSE; break;
        default:
            u->common.posix_errno = EINVAL;
            return 0;
    }

    if(posix_fadvise(u->fd, offset, length, p_advise) < 0) {
        u->common.posix_errno = errno;
        return 0;
    }

    return 1;
#else
    /* We'll pretend to support this syscall as it's only a recommendation even
     * on systems that do support it. */
    return 1;
#endif
}

int efile_allocate(efile_data_t *d, Sint64 offset, Sint64 length) {
    efile_unix_t *u = (efile_unix_t*)d;
    int ret = -1;

    /* We prefer OS-specific methods, but fall back to posix_fallocate on
     * failure. It's unclear whether this has any practical benefit on
     * modern systems, but the old driver did it. */

#if defined(HAVE_FALLOCATE)
    /* Linux-specific */
    do {
        ret = fallocate(u->fd, 0, offset, length);
    } while(ret < 0 && errno == EINTR);
#elif defined(F_PREALLOCATE)
    /* Mac-specific */
    off_t original_position, eof_offset;
    fstore_t fs = {};

    if(offset < 0 || length < 0 || (offset > ERTS_SINT64_MAX - length)) {
        u->common.posix_errno = EINVAL;
        return 0;
    }

    original_position = lseek(u->fd, 0, SEEK_CUR);

    if(original_position < 0) {
        u->common.posix_errno = errno;
        return 0;
    }

    eof_offset = lseek(u->fd, 0, SEEK_END);

    if(eof_offset < 0 || lseek(u->fd, original_position, SEEK_SET) < 0) {
        u->common.posix_errno = errno;
        return 0;
    }

    if(offset + length <= eof_offset) {
        /* File is already large enough. */
        return 1;
    }

    fs.fst_flags = F_ALLOCATECONTIG;
    fs.fst_posmode = F_PEOFPOSMODE;
    fs.fst_offset = 0;
    fs.fst_length = (offset + length) - eof_offset;

    ret = fcntl(u->fd, F_PREALLOCATE, &fs);
    if(ret < 0) {
        fs.fst_flags = F_ALLOCATEALL;
        ret = fcntl(u->fd, F_PREALLOCATE, &fs);
    }

    if(ret >= 0) {
        /* We MUST truncate since F_PREALLOCATE works relative to end-of-file,
         * otherwise we will expand the file on repeated calls to
         * file:allocate/3 with the same arguments. */
        ret = ftruncate(u->fd, offset + length);
        if(ret < 0) {
            u->common.posix_errno = errno;
            return 0;
        }
    }
#elif !defined(HAVE_POSIX_FALLOCATE)
    u->common.posix_errno = ENOTSUP;
    return 0;
#endif

#ifdef HAVE_POSIX_FALLOCATE
    if(ret < 0) {
        do {
            ret = posix_fallocate(u->fd, offset, length);

            /* On Linux and Solaris for example, posix_fallocate() returns a
             * positive error number on error and it does not set errno. On
             * FreeBSD however (9.0 at least), it returns -1 on error and it
             * sets errno. */
            if (ret > 0) {
                errno = ret;
                ret = -1;
            }
        } while(ret < 0 && errno == EINTR);
    }
#endif

    if(ret < 0) {
        u->common.posix_errno = errno;
        return 0;
    }

    return 1;
}

int efile_truncate(efile_data_t *d) {
    efile_unix_t *u = (efile_unix_t*)d;
    off_t offset;

    offset = lseek(u->fd, 0, SEEK_CUR);

    if(offset < 0) {
        u->common.posix_errno = errno;
        return 0;
    }

    if(ftruncate(u->fd, offset) < 0) {
        u->common.posix_errno = errno;
        return 0;
    }

    return 1;
}

static void build_file_info(struct stat *data, efile_fileinfo_t *result) {
    if(S_ISCHR(data->st_mode) || S_ISBLK(data->st_mode)) {
        result->type = EFILE_FILETYPE_DEVICE;
    } else if(S_ISDIR(data->st_mode)) {
        result->type = EFILE_FILETYPE_DIRECTORY;
    } else if(S_ISREG(data->st_mode)) {
        result->type = EFILE_FILETYPE_REGULAR;
    } else if(S_ISLNK(data->st_mode)) {
        result->type = EFILE_FILETYPE_SYMLINK;
    } else {
        result->type = EFILE_FILETYPE_OTHER;
    }

    result->a_time = (Sint64)data->st_atime;
    result->m_time = (Sint64)data->st_mtime;
    result->c_time = (Sint64)data->st_ctime;
    result->size = data->st_size;

    result->major_device = data->st_dev;
    result->minor_device = data->st_rdev;
    result->links = data->st_nlink;
    result->inode = data->st_ino;
    result->mode = data->st_mode;
    result->uid = data->st_uid;
    result->gid = data->st_gid;
}

static void build_file_access(int readable, int writable,
        efile_fileinfo_t *result) {
    result->access = EFILE_ACCESS_NONE;

    if(readable) {
        result->access |= EFILE_ACCESS_READ;
    }
    if(writable) {
        result->access |= EFILE_ACCESS_WRITE;
    }
}

#if defined(NO_ACCESS) || !defined(HAVE_FACCESSAT)
/* For a platform that cannot ask: the owner bits of the mode. */
static void build_file_access_from_mode(struct stat *data,
        efile_fileinfo_t *result) {
    result->access = ((data->st_mode >> 6) & 07) >> 1;
}
#endif

static posix_errno_t read_info_path(const efile_path_t *path, int follow_links,
        efile_fileinfo_t *result) {
    struct stat data;

    if(follow_links) {
        if(stat((const char*)path->data, &data) < 0) {
            return errno;
        }
    } else {
        if(lstat((const char*)path->data, &data) < 0) {
            return errno;
        }
    }

    build_file_info(&data, result);

#ifndef NO_ACCESS
    build_file_access(access((const char*)path->data, R_OK) == 0,
                      access((const char*)path->data, W_OK) == 0, result);
#else
    build_file_access_from_mode(&data, result);
#endif

    return 0;
}

static int check_access(struct stat *st) {
    int ret = EFILE_ACCESS_NONE;

    if(st->st_uid == geteuid()) {
        if(st->st_mode & S_IRUSR) {
            ret |= EFILE_ACCESS_READ;
        }
        if(st->st_mode & S_IWUSR) {
            ret |= EFILE_ACCESS_WRITE;
        }
        return ret;
    }

    if(st->st_gid == getegid()) {
        if(st->st_mode & S_IRGRP) {
            ret |= EFILE_ACCESS_READ;
        }
        if(st->st_mode & S_IWGRP) {
            ret |= EFILE_ACCESS_WRITE;
        }
        return ret;
    }

    if(st->st_mode & S_IROTH) {
        ret |= EFILE_ACCESS_READ;
    }
    if(st->st_mode & S_IWOTH) {
        ret |= EFILE_ACCESS_WRITE;
    }
    return ret;
}

static posix_errno_t read_info_at(const efile_target_t *target,
        int follow_links, efile_fileinfo_t *result) {
#ifndef HAVE_FSTATAT
    (void)target;
    (void)follow_links;
    (void)result;

    return ENOTSUP;
#else
    struct efile_resolved resolved;
    struct stat data;
    posix_errno_t posix_errno;
    int resolve_flags, stat_flags;

    resolve_flags = EFILE_RESOLVE_SELF_OK;

    if(follow_links) {
        resolve_flags |= EFILE_RESOLVE_FOLLOW_LAST;
    }

    posix_errno = resolve_target(target, resolve_flags, &resolved);

    if(posix_errno != 0) {
        return posix_errno;
    }

    stat_flags = resolved.follow_last ? 0 : AT_SYMLINK_NOFOLLOW;

    if(fstatat(resolved.parent_fd, resolved.component, &data, stat_flags) < 0) {
        posix_errno = errno;
    } else {
        build_file_info(&data, result);

#if defined(HAVE_FACCESSAT) && !defined(NO_ACCESS)
        build_file_access(
            faccessat(resolved.parent_fd, resolved.component, R_OK, 0) == 0,
            faccessat(resolved.parent_fd, resolved.component, W_OK, 0) == 0,
            result);
#else
        build_file_access_from_mode(&data, result);
#endif
    }

    resolved_release(&resolved);

    return posix_errno;
#endif
}

posix_errno_t efile_read_info(const efile_target_t *target, int follow_links,
        efile_fileinfo_t *result) {
    switch(target->kind) {
    case EFILE_TARGET_PATH:
        return read_info_path(&target->name, follow_links, result);
    case EFILE_TARGET_AT:
    case EFILE_TARGET_ROOT:
        return read_info_at(target, follow_links, result);
    default:
        return EINVAL;
    }
}

posix_errno_t efile_read_handle_info(efile_data_t *d, efile_fileinfo_t *result) {
    struct stat data;
    efile_unix_t *u = (efile_unix_t*)d;

#ifdef HAVE_FSTAT
    if(fstat(u->fd, &data) < 0) {
        return errno;
    }

    build_file_info(&data, result);
    result->access = check_access(&data);

    return 0;
#else
    return ENOTSUP;
#endif
}

#define EFILE_MUTABLE_MODES \
    (S_ISUID | S_ISGID | S_IRWXU | S_IRWXG | S_IRWXO)

static posix_errno_t set_permissions_path(const efile_path_t *path,
        Uint32 permissions) {
    mode_t new_modes = permissions & EFILE_MUTABLE_MODES;

    if(chmod((const char*)path->data, new_modes) < 0) {
        new_modes &= ~(S_ISUID | S_ISGID);

        if (chmod((const char*)path->data, new_modes) < 0) {
            return errno;
        }
    }

    return 0;
}

static posix_errno_t set_permissions_at(const efile_target_t *target,
        Uint32 permissions) {
#ifndef HAVE_FCHMODAT
    (void)target;
    (void)permissions;

    return ENOTSUP;
#else
    struct efile_resolved resolved;
    mode_t new_modes = permissions & EFILE_MUTABLE_MODES;
    posix_errno_t posix_errno;
    int flags;

    posix_errno = resolve_target(target,
        EFILE_RESOLVE_FOLLOW_LAST | EFILE_RESOLVE_SELF_OK, &resolved);

    if(posix_errno != 0) {
        return posix_errno;
    }

    flags = resolved.follow_last ? 0 : AT_SYMLINK_NOFOLLOW;

    /* Some file systems refuse the set-user-ID and set-group-ID bits.
     * set_permissions_path drops those bits and makes the call again, and so
     * does this. */
    if(fchmodat(resolved.parent_fd, resolved.component, new_modes, flags) < 0) {
        new_modes &= ~(S_ISUID | S_ISGID);

        if(fchmodat(resolved.parent_fd, resolved.component, new_modes,
                    flags) < 0) {
            posix_errno = errno;
        }
    }

    resolved_release(&resolved);

    return posix_errno;
#endif
}

posix_errno_t efile_set_permissions(const efile_target_t *target, Uint32 permissions) {
    switch(target->kind) {
    case EFILE_TARGET_PATH:
        return set_permissions_path(&target->name, permissions);
    case EFILE_TARGET_AT:
    case EFILE_TARGET_ROOT:
        return set_permissions_at(target, permissions);
    default:
        return EINVAL;
    }
}

posix_errno_t efile_set_handle_permissions(efile_data_t *d, Uint32 permissions) {
    efile_unix_t *u = (efile_unix_t*)d;
    mode_t new_modes = permissions & EFILE_MUTABLE_MODES;

    /* Some file systems refuse the set-user-ID and set-group-ID bits. The path
     * variant drops them and retries, so this function does the same. */
    if(fchmod(u->fd, new_modes) < 0) {
        new_modes &= ~(S_ISUID | S_ISGID);

        if(fchmod(u->fd, new_modes) < 0) {
            return errno;
        }
    }

    return 0;
}

static posix_errno_t set_owner_path(const efile_path_t *path, Sint32 owner,
        Sint32 group) {
    if(chown((const char*)path->data, owner, group) < 0) {
        return errno;
    }

    return 0;
}

static posix_errno_t set_owner_at(const efile_target_t *target, Sint32 owner,
        Sint32 group) {
#ifndef HAVE_FCHOWNAT
    (void)target;
    (void)owner;
    (void)group;

    return ENOTSUP;
#else
    struct efile_resolved resolved;
    posix_errno_t posix_errno;
    int flags;

    posix_errno = resolve_target(target,
        EFILE_RESOLVE_FOLLOW_LAST | EFILE_RESOLVE_SELF_OK, &resolved);

    if(posix_errno != 0) {
        return posix_errno;
    }

    flags = resolved.follow_last ? 0 : AT_SYMLINK_NOFOLLOW;

    if(fchownat(resolved.parent_fd, resolved.component, owner, group,
                flags) < 0) {
        posix_errno = errno;
    }

    resolved_release(&resolved);

    return posix_errno;
#endif
}

posix_errno_t efile_set_owner(const efile_target_t *target, Sint32 owner, Sint32 group) {
    switch(target->kind) {
    case EFILE_TARGET_PATH:
        return set_owner_path(&target->name, owner, group);
    case EFILE_TARGET_AT:
    case EFILE_TARGET_ROOT:
        return set_owner_at(target, owner, group);
    default:
        return EINVAL;
    }
}

posix_errno_t efile_set_handle_owner(efile_data_t *d, Sint32 owner, Sint32 group) {
    efile_unix_t *u = (efile_unix_t*)d;

    if(fchown(u->fd, owner, group) < 0) {
        return errno;
    }

    return 0;
}

static posix_errno_t set_time_path(const efile_path_t *path, Sint64 a_time,
        Sint64 m_time, Sint64 c_time) {
    struct utimbuf tval;

    tval.actime = (time_t)a_time;
    tval.modtime = (time_t)m_time;

    (void)c_time;

    if(utime((const char*)path->data, &tval) < 0) {
        return errno;
    }

    return 0;
}

static posix_errno_t set_time_at(const efile_target_t *target, Sint64 a_time,
        Sint64 m_time, Sint64 c_time) {
#ifndef HAVE_UTIMENSAT
    (void)target;
    (void)a_time;
    (void)m_time;
    (void)c_time;

    return ENOTSUP;
#else
    struct efile_resolved resolved;
    struct timespec times[2];
    posix_errno_t posix_errno;
    int flags;

    /* Unix cannot set the creation time, and set_time_path ignores it too. */
    (void)c_time;

    posix_errno = resolve_target(target,
        EFILE_RESOLVE_FOLLOW_LAST | EFILE_RESOLVE_SELF_OK, &resolved);

    if(posix_errno != 0) {
        return posix_errno;
    }

    times[0].tv_sec = (time_t)a_time;
    times[0].tv_nsec = 0;
    times[1].tv_sec = (time_t)m_time;
    times[1].tv_nsec = 0;

    flags = resolved.follow_last ? 0 : AT_SYMLINK_NOFOLLOW;

    if(utimensat(resolved.parent_fd, resolved.component, times, flags) < 0) {
        posix_errno = errno;
    }

    resolved_release(&resolved);

    return posix_errno;
#endif
}

posix_errno_t efile_set_time(const efile_target_t *target, Sint64 a_time,
        Sint64 m_time, Sint64 c_time) {
    switch(target->kind) {
    case EFILE_TARGET_PATH:
        return set_time_path(&target->name, a_time, m_time, c_time);
    case EFILE_TARGET_AT:
    case EFILE_TARGET_ROOT:
        return set_time_at(target, a_time, m_time, c_time);
    default:
        return EINVAL;
    }
}

posix_errno_t efile_set_handle_time(efile_data_t *d, Sint64 a_time, Sint64 m_time,
        Sint64 c_time) {
#if defined(HAVE_FUTIMENS) || defined(HAVE_FUTIMES)
    efile_unix_t *u = (efile_unix_t*)d;

    /* Unix cannot set the creation time, so the path variant ignores it too. */
    (void)c_time;

#ifdef HAVE_FUTIMENS
    {
        struct timespec times[2];

        times[0].tv_sec = (time_t)a_time;
        times[0].tv_nsec = 0;
        times[1].tv_sec = (time_t)m_time;
        times[1].tv_nsec = 0;

        if(futimens(u->fd, times) < 0) {
            return errno;
        }
    }
#else
    {
        struct timeval times[2];

        times[0].tv_sec = (time_t)a_time;
        times[0].tv_usec = 0;
        times[1].tv_sec = (time_t)m_time;
        times[1].tv_usec = 0;

        if(futimes(u->fd, times) < 0) {
            return errno;
        }
    }
#endif

    return 0;
#else
    (void)d;
    (void)a_time;
    (void)m_time;
    (void)c_time;

    return ENOTSUP;
#endif
}

/* Reads a link into a binary, growing the buffer until the result fits. The
 * reader either reads a path, or reads a name against an open directory. */
typedef ssize_t (*read_link_fun_t)(void *context, char *buffer, size_t size);

static posix_errno_t read_link_into_binary(ErlNifEnv *env,
        read_link_fun_t read_link_fun, void *context, ERL_NIF_TERM *result) {
    ErlNifBinary result_bin;

    if(!enif_alloc_binary(256, &result_bin)) {
        return ENOMEM;
    }

    for(;;) {
        ssize_t bytes_copied;

        bytes_copied = read_link_fun(context, (char*)result_bin.data,
            result_bin.size);

        if(bytes_copied <= 0) {
            posix_errno_t saved_errno = errno;
            enif_release_binary(&result_bin);
            return saved_errno;
        } else if(bytes_copied < result_bin.size) {
            if(!enif_realloc_binary(&result_bin, bytes_copied)) {
                enif_release_binary(&result_bin);
                return ENOMEM;
            }

            (*result) = enif_make_binary(env, &result_bin);

            return 0;
        }

        /* The result didn't fit into the buffer, so we'll try again with a
         * larger one. */

        if(!enif_realloc_binary(&result_bin, result_bin.size * 2)) {
            enif_release_binary(&result_bin);
            return ENOMEM;
        }
    }
}

static ssize_t read_link_from_path(void *context, char *buffer, size_t size) {
    const efile_path_t *path = (const efile_path_t*)context;

    return readlink((const char*)path->data, buffer, size);
}

static posix_errno_t read_link_path(ErlNifEnv *env, const efile_path_t *path,
        ERL_NIF_TERM *result) {
    return read_link_into_binary(env, read_link_from_path, (void*)path, result);
}

#ifdef HAVE_READLINKAT
static ssize_t read_link_from_dir(void *context, char *buffer, size_t size) {
    struct efile_resolved *resolved = (struct efile_resolved*)context;

    return readlinkat(resolved->parent_fd, resolved->component, buffer, size);
}
#endif

static posix_errno_t read_link_at(ErlNifEnv *env, const efile_target_t *target,
        ERL_NIF_TERM *result) {
#ifndef HAVE_READLINKAT
    (void)env;
    (void)target;
    (void)result;

    return ENOTSUP;
#else
    struct efile_resolved resolved;
    posix_errno_t posix_errno;

    posix_errno = resolve_target(target, 0, &resolved);

    if(posix_errno != 0) {
        return posix_errno;
    }

    posix_errno = read_link_into_binary(env, read_link_from_dir, &resolved,
                                        result);

    resolved_release(&resolved);

    return posix_errno;
#endif
}

posix_errno_t efile_read_link(ErlNifEnv *env, const efile_target_t *target,
        ERL_NIF_TERM *result) {
    switch(target->kind) {
    case EFILE_TARGET_PATH:
        return read_link_path(env, &target->name, result);
    case EFILE_TARGET_AT:
    case EFILE_TARGET_ROOT:
        return read_link_at(env, target, result);
    default:
        return EINVAL;
    }
}

static int is_ignored_name(int name_length, const char *name) {
    if(name_length == 1 && name[0] == '.') {
        return 1;
    } else if(name_length == 2 && memcmp(name, "..", 2) == 0) {
        return 1;
    }

    return 0;
}

/* Reads all entries of dir_stream into a list. This function always closes the
 * stream, on success and on failure. */
static posix_errno_t list_dir_stream(ErlNifEnv *env, DIR *dir_stream, ERL_NIF_TERM *result) {
    ERL_NIF_TERM list_head;
    struct dirent *dir_entry;

    list_head = enif_make_list(env, 0);
    dir_entry = readdir(dir_stream);

    while(dir_entry != NULL) {
        int name_length = strlen(dir_entry->d_name);

        if(!is_ignored_name(name_length, dir_entry->d_name)) {
            unsigned char *name_bytes;
            ERL_NIF_TERM name_term;

            name_bytes = enif_make_new_binary(env, name_length, &name_term);
            sys_memcpy(name_bytes, dir_entry->d_name, name_length);

            list_head = enif_make_list_cell(env, name_term, list_head);
        }

        dir_entry = readdir(dir_stream);
    }

    (*result) = list_head;
    closedir(dir_stream);

    return 0;
}

static posix_errno_t list_dir_path(ErlNifEnv *env, const efile_path_t *path,
        ERL_NIF_TERM *result) {
    DIR *dir_stream;

    dir_stream = opendir((const char*)path->data);
    if(dir_stream == NULL) {
        posix_errno_t saved_errno = errno;
        *result = enif_make_list(env, 0);
        return saved_errno;
    }

    return list_dir_stream(env, dir_stream, result);
}

static posix_errno_t list_dir_at(ErlNifEnv *env, const efile_target_t *target,
        ERL_NIF_TERM *result) {
#if !defined(HAVE_OPENAT) || !defined(HAVE_FDOPENDIR)
    (void)target;

    *result = enif_make_list(env, 0);
    return ENOTSUP;
#else
    struct efile_resolved resolved;
    DIR *dir_stream;
    posix_errno_t posix_errno;
    int fd, flags;

    posix_errno = resolve_target(target,
        EFILE_RESOLVE_FOLLOW_LAST | EFILE_RESOLVE_SELF_OK, &resolved);

    if(posix_errno != 0) {
        *result = enif_make_list(env, 0);
        return posix_errno;
    }

    flags = O_RDONLY;

#ifdef O_DIRECTORY
    flags |= O_DIRECTORY;
#endif

#ifdef O_NOFOLLOW
    if(!resolved.follow_last) {
        flags |= O_NOFOLLOW;
    }
#endif

    do {
        fd = openat(resolved.parent_fd, resolved.component, flags);
    } while(fd == -1 && errno == EINTR);

    resolved_release(&resolved);

    if(fd == -1) {
        posix_errno_t saved_errno = errno;
        *result = enif_make_list(env, 0);
        return saved_errno;
    }

    dir_stream = fdopendir(fd);

    if(dir_stream == NULL) {
        posix_errno_t saved_errno = errno;
        close(fd);
        *result = enif_make_list(env, 0);
        return saved_errno;
    }

    /* list_dir_stream closes the stream, which closes the descriptor. */
    return list_dir_stream(env, dir_stream, result);
#endif
}

posix_errno_t efile_list_dir(ErlNifEnv *env, const efile_target_t *target,
        ERL_NIF_TERM *result) {
    switch(target->kind) {
    case EFILE_TARGET_PATH:
        return list_dir_path(env, &target->name, result);
    case EFILE_TARGET_AT:
    case EFILE_TARGET_ROOT:
        return list_dir_at(env, target, result);
    default:
        return EINVAL;
    }
}

posix_errno_t efile_list_handle_dir(ErlNifEnv *env, efile_data_t *d, ERL_NIF_TERM *result) {
#ifndef HAVE_FDOPENDIR
    (void)d;

    *result = enif_make_list(env, 0);
    return ENOTSUP;
#else
    efile_unix_t *u = (efile_unix_t*)d;
    DIR *dir_stream;
    int fd;

    /* fdopendir becomes the owner of the descriptor. closedir would then close
     * the descriptor of our resource, so we supply a copy instead. */
    fd = dup(u->fd);

    if(fd == -1) {
        posix_errno_t saved_errno = errno;
        *result = enif_make_list(env, 0);
        return saved_errno;
    }

    dir_stream = fdopendir(fd);
    if(dir_stream == NULL) {
        posix_errno_t saved_errno = errno;
        close(fd);
        *result = enif_make_list(env, 0);
        return saved_errno;
    }

    /* The copied descriptor shares its file offset with the original. An
     * earlier call may have left that offset part-way through the directory. */
    rewinddir(dir_stream);

    return list_dir_stream(env, dir_stream, result);
#endif
}

static posix_errno_t rename_path(const efile_path_t *old_path,
        const efile_path_t *new_path) {
    if(rename((const char*)old_path->data, (const char*)new_path->data) < 0) {
        if(errno == ENOTEMPTY) {
            return EEXIST;
        }

        if(strcmp((const char*)old_path->data, "/") == 0) {
            /* Alpha reports renaming / as EBUSY and Linux reports it as EACCES
             * instead of EINVAL.*/
             return EINVAL;
        }

        return errno;
    }

    return 0;
}

static posix_errno_t rename_at(const efile_target_t *old_target,
        const efile_target_t *new_target) {
#ifndef HAVE_RENAMEAT
    (void)old_target;
    (void)new_target;

    return ENOTSUP;
#else
    struct efile_resolved old_resolved, new_resolved;
    posix_errno_t posix_errno;

    posix_errno = resolve_either(old_target, 0, &old_resolved);

    if(posix_errno != 0) {
        return posix_errno;
    }

    posix_errno = resolve_either(new_target, 0, &new_resolved);

    if(posix_errno != 0) {
        resolved_release(&old_resolved);
        return posix_errno;
    }

    if(renameat(old_resolved.parent_fd, old_resolved.component,
                new_resolved.parent_fd, new_resolved.component) < 0) {
        posix_errno = errno;

        if(posix_errno == ENOTEMPTY) {
            posix_errno = EEXIST;
        }
    }

    resolved_release(&new_resolved);
    resolved_release(&old_resolved);

    return posix_errno;
#endif
}

posix_errno_t efile_rename(const efile_target_t *old_target,
        const efile_target_t *new_target) {
    if(old_target->kind == EFILE_TARGET_PATH
       && new_target->kind == EFILE_TARGET_PATH) {
        return rename_path(&old_target->name, &new_target->name);
    }

    return rename_at(old_target, new_target);
}

static posix_errno_t make_hard_link_path(const efile_path_t *existing_path,
        const efile_path_t *new_path) {
    if(link((const char*)existing_path->data, (const char*)new_path->data) < 0) {
        return errno;
    }

    return 0;
}

static posix_errno_t make_hard_link_at(const efile_target_t *existing_target,
        const efile_target_t *new_target) {
#ifndef HAVE_LINKAT
    (void)existing_target;
    (void)new_target;

    return ENOTSUP;
#else
    struct efile_resolved existing_resolved, new_resolved;
    posix_errno_t posix_errno;

    posix_errno = resolve_either(existing_target, 0, &existing_resolved);

    if(posix_errno != 0) {
        return posix_errno;
    }

    posix_errno = resolve_either(new_target, 0, &new_resolved);

    if(posix_errno != 0) {
        resolved_release(&existing_resolved);
        return posix_errno;
    }

    if(linkat(existing_resolved.parent_fd, existing_resolved.component,
              new_resolved.parent_fd, new_resolved.component, 0) < 0) {
        posix_errno = errno;
    }

    resolved_release(&new_resolved);
    resolved_release(&existing_resolved);

    return posix_errno;
#endif
}

posix_errno_t efile_make_hard_link(const efile_target_t *existing_target,
        const efile_target_t *new_target) {
    if(existing_target->kind == EFILE_TARGET_PATH
       && new_target->kind == EFILE_TARGET_PATH) {
        return make_hard_link_path(&existing_target->name, &new_target->name);
    }

    return make_hard_link_at(existing_target, new_target);
}

static posix_errno_t make_soft_link_path(const efile_path_t *existing_path,
        const efile_path_t *new_path) {
    if(symlink((const char*)existing_path->data, (const char*)new_path->data) < 0) {
        return errno;
    }

    return 0;
}

/* The target of a link is stored as it is given, so only the new name is
 * resolved against a directory. */
static posix_errno_t make_soft_link_at(const efile_path_t *existing_path,
        const efile_target_t *new_target) {
#ifndef HAVE_SYMLINKAT
    (void)existing_path;
    (void)new_target;

    return ENOTSUP;
#else
    struct efile_resolved new_resolved;
    posix_errno_t posix_errno;

    posix_errno = resolve_target(new_target, 0, &new_resolved);

    if(posix_errno != 0) {
        return posix_errno;
    }

    if(symlinkat((const char*)existing_path->data, new_resolved.parent_fd,
                 new_resolved.component) < 0) {
        posix_errno = errno;
    }

    resolved_release(&new_resolved);

    return posix_errno;
#endif
}

posix_errno_t efile_make_soft_link(const efile_path_t *existing_path,
        const efile_target_t *new_target) {
    switch(new_target->kind) {
    case EFILE_TARGET_PATH:
        return make_soft_link_path(existing_path, &new_target->name);
    case EFILE_TARGET_AT:
    case EFILE_TARGET_ROOT:
        return make_soft_link_at(existing_path, new_target);
    default:
        return EINVAL;
    }
}

static posix_errno_t make_dir_path(const efile_path_t *path) {
#ifdef NO_MKDIR_MODE
    if(mkdir((const char*)path->data) < 0) {
#else
    if(mkdir((const char*)path->data, DIR_MODE) < 0) {
#endif
        return errno;
    }

    return 0;
}

static posix_errno_t make_dir_at(const efile_target_t *target) {
#ifndef HAVE_MKDIRAT
    (void)target;

    return ENOTSUP;
#else
    struct efile_resolved resolved;
    posix_errno_t posix_errno;

    posix_errno = resolve_target(target, 0, &resolved);

    if(posix_errno != 0) {
        return posix_errno;
    }

    if(mkdirat(resolved.parent_fd, resolved.component, DIR_MODE) < 0) {
        posix_errno = errno;
    }

    resolved_release(&resolved);

    return posix_errno;
#endif
}

posix_errno_t efile_make_dir(const efile_target_t *target) {
    switch(target->kind) {
    case EFILE_TARGET_PATH:
        return make_dir_path(&target->name);
    case EFILE_TARGET_AT:
    case EFILE_TARGET_ROOT:
        return make_dir_at(target);
    default:
        return EINVAL;
    }
}

static posix_errno_t del_file_path(const efile_path_t *path) {
    if(unlink((const char*)path->data) < 0) {
        /* Linux sets the wrong error code. */
        if(errno == EISDIR) {
            return EPERM;
        }

        return errno;
    }

    return 0;
}

static posix_errno_t del_file_at(const efile_target_t *target) {
#ifndef HAVE_UNLINKAT
    (void)target;

    return ENOTSUP;
#else
    struct efile_resolved resolved;
    posix_errno_t posix_errno;

    posix_errno = resolve_target(target, 0, &resolved);

    if(posix_errno != 0) {
        return posix_errno;
    }

    if(unlinkat(resolved.parent_fd, resolved.component, 0) < 0) {
        posix_errno = errno;

        /* Linux sets the wrong error code. */
        if(posix_errno == EISDIR) {
            posix_errno = EPERM;
        }
    }

    resolved_release(&resolved);

    return posix_errno;
#endif
}

posix_errno_t efile_del_file(const efile_target_t *target) {
    switch(target->kind) {
    case EFILE_TARGET_PATH:
        return del_file_path(&target->name);
    case EFILE_TARGET_AT:
    case EFILE_TARGET_ROOT:
        return del_file_at(target);
    default:
        return EINVAL;
    }
}

static posix_errno_t del_dir_path(const efile_path_t *path) {
    if(rmdir((const char*)path->data) < 0) {
        posix_errno_t saved_errno = errno;

        if(saved_errno == ENOTEMPTY) {
            saved_errno = EEXIST;
        }

        /* The error code might be wrong if we're trying to delete the current
         * directory. */
        if(saved_errno == EEXIST) {
            struct stat path_stat, cwd_stat;
            int has_stat;

            has_stat = (stat((const char*)path->data, &path_stat) == 0);
            has_stat &= (stat(".", &cwd_stat) == 0);

            if(has_stat && path_stat.st_ino == cwd_stat.st_ino) {
                if(path_stat.st_dev == cwd_stat.st_dev) {
                    return EINVAL;
                }
            }
        }

        return saved_errno;
    }

    return 0;
}

static posix_errno_t del_dir_at(const efile_target_t *target) {
#ifndef HAVE_UNLINKAT
    (void)target;

    return ENOTSUP;
#else
    struct efile_resolved resolved;
    posix_errno_t posix_errno;

    posix_errno = resolve_target(target, 0, &resolved);

    if(posix_errno != 0) {
        return posix_errno;
    }

    if(unlinkat(resolved.parent_fd, resolved.component, AT_REMOVEDIR) < 0) {
        posix_errno = errno;

        if(posix_errno == ENOTEMPTY) {
            posix_errno = EEXIST;
        }
    }

    resolved_release(&resolved);

    return posix_errno;
#endif
}

posix_errno_t efile_del_dir(const efile_target_t *target) {
    switch(target->kind) {
    case EFILE_TARGET_PATH:
        return del_dir_path(&target->name);
    case EFILE_TARGET_AT:
    case EFILE_TARGET_ROOT:
        return del_dir_at(target);
    default:
        return EINVAL;
    }
}

posix_errno_t efile_set_cwd(const efile_path_t *path) {
    if(chdir((const char*)path->data) < 0) {
        return errno;
    }

    return 0;
}

posix_errno_t efile_get_device_cwd(ErlNifEnv *env, int device_index, ERL_NIF_TERM *result) {
    (void)device_index;
    (void)result;
    (void)env;

    return ENOTSUP;
}

posix_errno_t efile_get_cwd(ErlNifEnv *env, ERL_NIF_TERM *result) {
    ErlNifBinary result_bin;
    size_t bytes_copied;

    if(!enif_alloc_binary(256, &result_bin)) {
        return ENOMEM;
    }

    while(getcwd((char*)result_bin.data, result_bin.size) == NULL) {
        posix_errno_t saved_errno = errno;

        if(saved_errno != ERANGE) {
            enif_release_binary(&result_bin);
            return saved_errno;
        } else {
            if(!enif_realloc_binary(&result_bin, result_bin.size * 2)) {
                enif_release_binary(&result_bin);
                return ENOMEM;
            }
        }
    }

    /* getcwd(2) guarantees null-termination. */
    bytes_copied = strlen((const char*)result_bin.data);

    if(!enif_realloc_binary(&result_bin, bytes_copied)) {
        enif_release_binary(&result_bin);
        return ENOMEM;
    }

    (*result) = enif_make_binary(env, &result_bin);

    return 0;
}

posix_errno_t efile_altname(ErlNifEnv *env, const efile_path_t *path, ERL_NIF_TERM *result) {
    (void)path;
    (void)result;

    return ENOTSUP;
}
