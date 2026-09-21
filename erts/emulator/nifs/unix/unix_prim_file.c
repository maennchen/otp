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

/* Wraps a descriptor that open(2) or openat(2) returned in a resource. The
 * path is used for the type checks, and for those only. */
static posix_errno_t build_open_resource(const efile_path_t *path, int fd,
        enum efile_modes_t modes, ErlNifResourceType *nif_type, efile_data_t **d) {
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

/* Returns the open(2) flags and the creation mode for the given modes. */
static void get_open_flags(enum efile_modes_t modes, int *flags, int *mode) {
    *flags = get_flags(modes);

    if(modes & EFILE_MODE_DIRECTORY) {
        *mode = DIR_MODE;
#ifdef O_DIRECTORY
        *flags |= O_DIRECTORY;
#endif
    } else {
        *mode = FILE_MODE;
    }
}

posix_errno_t efile_open(const efile_path_t *path, enum efile_modes_t modes,
        ErlNifResourceType *nif_type, efile_data_t **d) {

    int mode, flags, fd;

    get_open_flags(modes, &flags, &mode);

    do {
        fd = open((const char*)path->data, flags, mode);
    } while(fd == -1 && errno == EINTR);

    return build_open_resource(path, fd, modes, nif_type, d);
}

posix_errno_t efile_open_at(efile_data_t *dir, const efile_path_t *path,
        enum efile_modes_t modes, ErlNifResourceType *nif_type, efile_data_t **d) {
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

    return build_open_resource(path, fd, modes, nif_type, d);
#endif
}

/* The most links that may be followed while one name is resolved. The limit
 * stops a cycle of links from resolving forever. */
#define EFILE_MAX_LINK_DEPTH 32

/* The most components a name may have. A name that is longer than this is
 * refused rather than resolved, so the walk cannot be made to run for an
 * unreasonable time. */
#define EFILE_MAX_WALK_STEPS 4096

/* One position in a walk from a root directory.
 *
 * "fd" is the directory the next component is resolved against. "depth" counts
 * how far the walk has moved below the root, so that ".." can be refused when
 * it would leave the root. The root itself is at depth 0 and is never closed
 * by the walk. */
struct root_walk {
    int root_fd;
    int fd;
    int depth;
    int links_followed;
};

static void walk_init(struct root_walk *walk, int root_fd) {
    walk->root_fd = root_fd;
    walk->fd = root_fd;
    walk->depth = 0;
    walk->links_followed = 0;
}

static void walk_close(struct root_walk *walk) {
    if(walk->fd != walk->root_fd && walk->fd != -1) {
        close(walk->fd);
    }

    walk->fd = walk->root_fd;
}

/* Moves the walk to the root, which is where an absolute name and the target
 * of an absolute link both start. */
static void walk_reset(struct root_walk *walk) {
    walk_close(walk);
    walk->depth = 0;
}

static void walk_enter(struct root_walk *walk, int fd) {
    walk_close(walk);
    walk->fd = fd;
    walk->depth++;
}

/* Moves the walk to the directory above. The root has nothing above it, so a
 * caller that asks for that is leaving the root. */
static posix_errno_t walk_leave(struct root_walk *walk) {
    int parent_fd;

    if(walk->depth == 0) {
        return EXDEV;
    }

    do {
        parent_fd = openat(walk->fd, "..", O_RDONLY | O_NOFOLLOW
#ifdef O_DIRECTORY
                           | O_DIRECTORY
#endif
                           );
    } while(parent_fd == -1 && errno == EINTR);

    if(parent_fd == -1) {
        return errno;
    }

    walk_close(walk);
    walk->fd = parent_fd;
    walk->depth--;

    return 0;
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

/* Resolves every component of "name" but the last one, so that the caller is
 * left holding the directory the last component belongs to.
 *
 * On success "last" points at the last component and "last_length" holds its
 * length. A name whose last component is "." or ".." has no last component of
 * its own, and is resolved in full, leaving "last_length" at 0.
 *
 * The last component is always a plain name. It holds no separator, and it is
 * never "." or ".."; the walk resolves both of those itself. A caller may
 * therefore give it to an *at call without the system reaching a file outside
 * the directory the walk ended on. */
static posix_errno_t walk_to_last(struct root_walk *walk, const char *name,
        const char **last, size_t *last_length) {
    int steps = 0;

    /* A name that starts at the root is resolved from the root, as it would be
     * if the root were the whole file system. */
    if(name[0] == '/') {
        walk_reset(walk);

        while(name[0] == '/') {
            name++;
        }
    }

    for(;;) {
        size_t length, next;
        int fd;

        if(steps++ > EFILE_MAX_WALK_STEPS) {
            return ENAMETOOLONG;
        }

        length = component_length(name, &next);

        if(length == 0) {
            /* The name ended, so the walk is at the directory that holds it
             * and there is no component left to open. */
            *last = name;
            *last_length = 0;

            return 0;
        }

        if(component_is(name, length, ".")) {
            name += next;
            continue;
        }

        if(component_is(name, length, "..")) {
            posix_errno_t posix_errno = walk_leave(walk);

            if(posix_errno != 0) {
                return posix_errno;
            }

            name += next;
            continue;
        }

        if(name[next] == '\0' && next == length) {
            /* This is the last component, and the caller opens it. The checks
             * above have already consumed "." and "..", and a name that holds
             * a separator does not reach here, so what is returned is a plain
             * name. */
            ASSERT(!component_is(name, length, ".")
                   && !component_is(name, length, ".."));
            ASSERT(memchr(name, '/', length) == NULL);

            *last = name;
            *last_length = length;

            return 0;
        }

        /* A component in the middle of the name has to be a directory, so it
         * is opened as one. The link flag makes a symbolic link fail rather
         * than be followed, so that a link is seen here and followed only as
         * far as the root. */
        {
            char component[PATH_MAX];

            if(length >= sizeof(component)) {
                return ENAMETOOLONG;
            }

            sys_memcpy(component, name, length);
            component[length] = '\0';

            do {
                fd = openat(walk->fd, component, O_RDONLY | O_NOFOLLOW
#ifdef O_DIRECTORY
                            | O_DIRECTORY
#endif
                            );
            } while(fd == -1 && errno == EINTR);

            if(fd == -1) {
                posix_errno_t saved_errno = errno;

                /* ELOOP means the component is a symbolic link, because the
                 * link flag stopped the system from following it. ENOTDIR
                 * means the same on the systems that report it that way. */
                if(saved_errno == ELOOP || saved_errno == EMLINK
                   || saved_errno == ENOTDIR) {
                    char target[PATH_MAX];
                    ssize_t target_length;

                    if(walk->links_followed++ > EFILE_MAX_LINK_DEPTH) {
                        return ELOOP;
                    }

                    target_length = readlinkat(walk->fd, component, target,
                                               sizeof(target) - 1);

                    if(target_length < 0) {
                        /* Not a link after all, so report what the open
                         * reported. */
                        return saved_errno;
                    }

                    target[target_length] = '\0';

                    /* The link is followed by resolving its target from here,
                     * and the rest of the name is then resolved from wherever
                     * the target led. */
                    {
                        const char *ignored_last;
                        size_t ignored_length;
                        posix_errno_t posix_errno;

                        posix_errno = walk_to_last(walk, target,
                                                   &ignored_last,
                                                   &ignored_length);

                        if(posix_errno != 0) {
                            return posix_errno;
                        }

                        if(ignored_length > 0) {
                            /* The target named a file rather than a
                             * directory, so open that as the next step. */
                            char last_component[PATH_MAX];
                            int target_fd;

                            if(ignored_length >= sizeof(last_component)) {
                                return ENAMETOOLONG;
                            }

                            sys_memcpy(last_component, ignored_last,
                                       ignored_length);
                            last_component[ignored_length] = '\0';

                            do {
                                target_fd = openat(walk->fd, last_component,
                                    O_RDONLY | O_NOFOLLOW
#ifdef O_DIRECTORY
                                    | O_DIRECTORY
#endif
                                    );
                            } while(target_fd == -1 && errno == EINTR);

                            if(target_fd == -1) {
                                return errno;
                            }

                            walk_enter(walk, target_fd);
                        }
                    }

                    name += next;
                    continue;
                }

                return saved_errno;
            }

            walk_enter(walk, fd);
        }

        name += next;
    }
}

/* Turns a target that is not a path into the directory its last component
 * belongs to, and that component.
 *
 * A name in an open directory is used as it is, against that directory. A name
 * in a root is walked, so it cannot leave the root, and the walk answers with
 * the directory that holds its last component.
 *
 * The component is always a plain name, so the *at call the caller makes
 * cannot reach a file outside the directory it is given.
 *
 * "owned" says whether the caller closes the descriptor. */
static posix_errno_t resolve_target(const efile_target_t *target,
        char *component, size_t component_size, const char **name,
        int *parent_fd, int *owned) {
#if !defined(HAVE_OPENAT) || !defined(HAVE_READLINKAT)
    (void)target;
    (void)component;
    (void)component_size;
    (void)name;
    (void)parent_fd;
    (void)owned;

    return ENOTSUP;
#else
    efile_unix_t *u = (efile_unix_t*)target->dir;

    if(target->kind == EFILE_TARGET_AT) {
        *name = (const char*)target->name.data;
        *parent_fd = u->fd;
        *owned = 0;

        return 0;
    }

    {
        struct root_walk walk;
        posix_errno_t posix_errno;
        const char *last;
        size_t last_length;

        walk_init(&walk, u->fd);

        posix_errno = walk_to_last(&walk, (const char*)target->name.data,
                                   &last, &last_length);

        if(posix_errno != 0) {
            walk_close(&walk);
            return posix_errno;
        }

        if(last_length == 0) {
            /* The name has no last component of its own, so there is nothing
             * for the caller to act on. */
            walk_close(&walk);
            return EISDIR;
        }

        if(last_length >= component_size) {
            walk_close(&walk);
            return ENAMETOOLONG;
        }

        sys_memcpy(component, last, last_length);
        component[last_length] = '\0';

        *name = component;

        /* The walk holds the directory, so it is handed over rather than
         * closed. */
        if(walk.fd == walk.root_fd) {
            *parent_fd = walk.root_fd;
            *owned = 0;
        } else {
            *parent_fd = walk.fd;
            *owned = 1;
        }

        return 0;
    }
#endif
}

posix_errno_t efile_open_in_root(efile_data_t *root, const efile_path_t *path,
        enum efile_modes_t modes, ErlNifResourceType *nif_type, efile_data_t **d) {
#if !defined(HAVE_OPENAT) || !defined(HAVE_READLINKAT)
    (void)root;
    (void)path;
    (void)modes;
    (void)nif_type;

    (*d) = NULL;
    return ENOTSUP;
#else
    efile_unix_t *u = (efile_unix_t*)root;
    posix_errno_t posix_errno;
    struct root_walk walk;
    char name[PATH_MAX];
    const char *last;
    size_t last_length;
    int mode, flags, fd;

    if(path->size > sizeof(name)) {
        (*d) = NULL;
        return ENAMETOOLONG;
    }

    sys_memcpy(name, path->data, path->size);
    name[sizeof(name) - 1] = '\0';

    get_open_flags(modes, &flags, &mode);
    walk_init(&walk, u->fd);

    /* Each turn resolves the name to the directory that holds its last
     * component, then opens that component. A last component that is a
     * symbolic link starts another turn with the target of the link, which is
     * resolved from the directory that holds the link. */
    for(;;) {
        char component[PATH_MAX];
        char target[PATH_MAX];
        ssize_t target_length;

        posix_errno = walk_to_last(&walk, name, &last, &last_length);

        if(posix_errno != 0) {
            walk_close(&walk);
            (*d) = NULL;

            return posix_errno;
        }

        if(last_length == 0) {
            /* The name resolved to a directory that the walk already holds,
             * so that directory is what the caller asked for. */
            do {
                fd = openat(walk.fd, ".", flags, mode);
            } while(fd == -1 && errno == EINTR);

            break;
        }

        if(last_length >= sizeof(component)) {
            walk_close(&walk);
            (*d) = NULL;

            return ENAMETOOLONG;
        }

        sys_memcpy(component, last, last_length);
        component[last_length] = '\0';

        /* The system would follow a symbolic link here, and the link can
         * reach a file outside the root. It is opened without following, and
         * followed by this loop instead. */
        do {
            fd = openat(walk.fd, component, flags | O_NOFOLLOW, mode);
        } while(fd == -1 && errno == EINTR);

        if(fd != -1 || (errno != ELOOP && errno != EMLINK)) {
            break;
        }

        target_length = readlinkat(walk.fd, component, target,
                                   sizeof(target) - 1);

        if(target_length < 0) {
            /* Not a link after all, so report what the open reported. */
            break;
        }

        if(walk.links_followed++ > EFILE_MAX_LINK_DEPTH) {
            walk_close(&walk);
            (*d) = NULL;

            return ELOOP;
        }

        target[target_length] = '\0';
        sys_memcpy(name, target, target_length + 1);
    }

    walk_close(&walk);

    return build_open_resource(path, fd, modes, nif_type, d);
#endif
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

posix_errno_t efile_read_info(const efile_path_t *path, int follow_links, efile_fileinfo_t *result) {
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
    result->access = EFILE_ACCESS_NONE;

    if(access((const char*)path->data, R_OK) == 0) {
        result->access |= EFILE_ACCESS_READ;
    }
    if(access((const char*)path->data, W_OK) == 0) {
        result->access |= EFILE_ACCESS_WRITE;
    }
#else
    /* Just look at read/write access for owner. */
    result->access = ((data.st_mode >> 6) & 07) >> 1;
#endif

    return 0;
}

posix_errno_t efile_read_info_at(efile_data_t *dir, const efile_path_t *path,
        int follow_links, efile_fileinfo_t *result) {
#if !defined(HAVE_FSTATAT)
    (void)dir;
    (void)path;
    (void)follow_links;
    (void)result;

    return ENOTSUP;
#else
    efile_unix_t *u = (efile_unix_t*)dir;
    struct stat data;
    int flags;

    flags = follow_links ? 0 : AT_SYMLINK_NOFOLLOW;

    if(fstatat(u->fd, (const char*)path->data, &data, flags) < 0) {
        return errno;
    }

    build_file_info(&data, result);

#if defined(HAVE_FACCESSAT) && !defined(NO_ACCESS)
    result->access = EFILE_ACCESS_NONE;

    if(faccessat(u->fd, (const char*)path->data, R_OK, 0) == 0) {
        result->access |= EFILE_ACCESS_READ;
    }
    if(faccessat(u->fd, (const char*)path->data, W_OK, 0) == 0) {
        result->access |= EFILE_ACCESS_WRITE;
    }
#else
    /* Just look at read/write access for owner. */
    result->access = ((data.st_mode >> 6) & 07) >> 1;
#endif

    return 0;
#endif
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

posix_errno_t efile_set_permissions(const efile_path_t *path, Uint32 permissions) {
    mode_t new_modes = permissions & EFILE_MUTABLE_MODES;

    if(chmod((const char*)path->data, new_modes) < 0) {
        new_modes &= ~(S_ISUID | S_ISGID);

        if (chmod((const char*)path->data, new_modes) < 0) {
            return errno;
        }
    }

    return 0;
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

posix_errno_t efile_set_owner(const efile_path_t *path, Sint32 owner, Sint32 group) {
    if(chown((const char*)path->data, owner, group) < 0) {
        return errno;
    }

    return 0;
}

posix_errno_t efile_set_permissions_at(efile_data_t *dir, const efile_path_t *path,
        Uint32 permissions) {
#ifndef HAVE_FCHMODAT
    (void)dir;
    (void)path;
    (void)permissions;

    return ENOTSUP;
#else
    efile_unix_t *u = (efile_unix_t*)dir;
    mode_t new_modes = permissions & EFILE_MUTABLE_MODES;

    /* Some file systems refuse the set-user-ID and set-group-ID bits. The path
     * variant drops them and retries, so this function does the same. */
    if(fchmodat(u->fd, (const char*)path->data, new_modes, 0) < 0) {
        new_modes &= ~(S_ISUID | S_ISGID);

        if(fchmodat(u->fd, (const char*)path->data, new_modes, 0) < 0) {
            return errno;
        }
    }

    return 0;
#endif
}

posix_errno_t efile_set_owner_at(efile_data_t *dir, const efile_path_t *path,
        Sint32 owner, Sint32 group) {
#ifndef HAVE_FCHOWNAT
    (void)dir;
    (void)path;
    (void)owner;
    (void)group;

    return ENOTSUP;
#else
    efile_unix_t *u = (efile_unix_t*)dir;

    if(fchownat(u->fd, (const char*)path->data, owner, group, 0) < 0) {
        return errno;
    }

    return 0;
#endif
}

posix_errno_t efile_set_time_at(efile_data_t *dir, const efile_path_t *path,
        Sint64 a_time, Sint64 m_time, Sint64 c_time) {
#ifndef HAVE_UTIMENSAT
    (void)dir;
    (void)path;
    (void)a_time;
    (void)m_time;
    (void)c_time;

    return ENOTSUP;
#else
    efile_unix_t *u = (efile_unix_t*)dir;
    struct timespec times[2];

    /* Unix cannot set the creation time, so the path variant ignores it too. */
    (void)c_time;

    times[0].tv_sec = (time_t)a_time;
    times[0].tv_nsec = 0;
    times[1].tv_sec = (time_t)m_time;
    times[1].tv_nsec = 0;

    if(utimensat(u->fd, (const char*)path->data, times, 0) < 0) {
        return errno;
    }

    return 0;
#endif
}

posix_errno_t efile_set_handle_owner(efile_data_t *d, Sint32 owner, Sint32 group) {
    efile_unix_t *u = (efile_unix_t*)d;

    if(fchown(u->fd, owner, group) < 0) {
        return errno;
    }

    return 0;
}

posix_errno_t efile_set_time(const efile_path_t *path, Sint64 a_time, Sint64 m_time, Sint64 c_time) {
    struct utimbuf tval;

    tval.actime = (time_t)a_time;
    tval.modtime = (time_t)m_time;

    (void)c_time;

    if(utime((const char*)path->data, &tval) < 0) {
        return errno;
    }

    return 0;
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

static ssize_t read_link_path(void *context, char *buffer, size_t size) {
    const efile_path_t *path = (const efile_path_t*)context;

    return readlink((const char*)path->data, buffer, size);
}

posix_errno_t efile_read_link(ErlNifEnv *env, const efile_path_t *path, ERL_NIF_TERM *result) {
    return read_link_into_binary(env, read_link_path, (void*)path, result);
}

#ifdef HAVE_READLINKAT
struct read_link_at_context {
    int dir_fd;
    const efile_path_t *path;
};

static ssize_t read_link_at_name(void *context, char *buffer, size_t size) {
    struct read_link_at_context *c = (struct read_link_at_context*)context;

    return readlinkat(c->dir_fd, (const char*)c->path->data, buffer, size);
}
#endif

posix_errno_t efile_read_link_at(ErlNifEnv *env, efile_data_t *dir,
        const efile_path_t *path, ERL_NIF_TERM *result) {
#ifndef HAVE_READLINKAT
    (void)env;
    (void)dir;
    (void)path;
    (void)result;

    return ENOTSUP;
#else
    efile_unix_t *u = (efile_unix_t*)dir;
    struct read_link_at_context context;

    context.dir_fd = u->fd;
    context.path = path;

    return read_link_into_binary(env, read_link_at_name, &context, result);
#endif
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

posix_errno_t efile_list_dir(ErlNifEnv *env, const efile_path_t *path, ERL_NIF_TERM *result) {
    DIR *dir_stream;

    dir_stream = opendir((const char*)path->data);
    if(dir_stream == NULL) {
        posix_errno_t saved_errno = errno;
        *result = enif_make_list(env, 0);
        return saved_errno;
    }

    return list_dir_stream(env, dir_stream, result);
}

posix_errno_t efile_list_dir_at(ErlNifEnv *env, efile_data_t *dir,
        const efile_path_t *path, ERL_NIF_TERM *result) {
#if !defined(HAVE_OPENAT) || !defined(HAVE_FDOPENDIR)
    (void)dir;
    (void)path;

    *result = enif_make_list(env, 0);
    return ENOTSUP;
#else
    efile_unix_t *u = (efile_unix_t*)dir;
    DIR *dir_stream;
    int fd;

    /* The name is resolved against the open directory, and the listing then
     * comes from the descriptor that openat returned. Neither step resolves a
     * path, so the caller lists the directory it named in the directory it
     * holds. */
    do {
        int flags = O_RDONLY;

#ifdef O_DIRECTORY
        flags |= O_DIRECTORY;
#endif

        fd = openat(u->fd, (const char*)path->data, flags);
    } while(fd == -1 && errno == EINTR);

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
    do {
        fd = dup(u->fd);
    } while(fd == -1 && errno == EINTR);

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

posix_errno_t efile_rename(const efile_path_t *old_path, const efile_path_t *new_path) {
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

posix_errno_t efile_rename_at(efile_data_t *old_dir, const efile_path_t *old_path,
        efile_data_t *new_dir, const efile_path_t *new_path) {
#ifndef HAVE_RENAMEAT
    (void)old_dir;
    (void)old_path;
    (void)new_dir;
    (void)new_path;

    return ENOTSUP;
#else
    efile_unix_t *old_u = (efile_unix_t*)old_dir;
    efile_unix_t *new_u = (efile_unix_t*)new_dir;

    if(renameat(old_u->fd, (const char*)old_path->data,
                new_u->fd, (const char*)new_path->data) < 0) {
        if(errno == ENOTEMPTY) {
            return EEXIST;
        }

        return errno;
    }

    return 0;
#endif
}

posix_errno_t efile_make_hard_link(const efile_path_t *existing_path, const efile_path_t *new_path) {
    if(link((const char*)existing_path->data, (const char*)new_path->data) < 0) {
        return errno;
    }

    return 0;
}

posix_errno_t efile_make_soft_link(const efile_path_t *existing_path, const efile_path_t *new_path) {
    if(symlink((const char*)existing_path->data, (const char*)new_path->data) < 0) {
        return errno;
    }

    return 0;
}

posix_errno_t efile_make_hard_link_at(efile_data_t *existing_dir,
        const efile_path_t *existing_path, efile_data_t *new_dir,
        const efile_path_t *new_path) {
#ifndef HAVE_LINKAT
    (void)existing_dir;
    (void)existing_path;
    (void)new_dir;
    (void)new_path;

    return ENOTSUP;
#else
    efile_unix_t *existing_u = (efile_unix_t*)existing_dir;
    efile_unix_t *new_u = (efile_unix_t*)new_dir;

    /* A hard link names a file that has to exist, so both names are resolved
     * against the directory they belong to. */
    if(linkat(existing_u->fd, (const char*)existing_path->data,
              new_u->fd, (const char*)new_path->data, 0) < 0) {
        return errno;
    }

    return 0;
#endif
}

posix_errno_t efile_make_soft_link_at(const efile_path_t *existing_path,
        efile_data_t *new_dir, const efile_path_t *new_path) {
#ifndef HAVE_SYMLINKAT
    (void)existing_path;
    (void)new_dir;
    (void)new_path;

    return ENOTSUP;
#else
    efile_unix_t *new_u = (efile_unix_t*)new_dir;

    /* Only the new name is resolved. The target is stored as it is given. */
    if(symlinkat((const char*)existing_path->data, new_u->fd,
                 (const char*)new_path->data) < 0) {
        return errno;
    }

    return 0;
#endif
}

posix_errno_t efile_make_dir(const efile_target_t *target) {
    const char *name = (const char*)target->name.data;

    if(target->kind == EFILE_TARGET_PATH) {
#ifdef NO_MKDIR_MODE
        if(mkdir(name) < 0) {
#else
        if(mkdir(name, DIR_MODE) < 0) {
#endif
            return errno;
        }

        return 0;
    }

#ifndef HAVE_MKDIRAT
    return ENOTSUP;
#else
    {
        posix_errno_t posix_errno;
        char component[PATH_MAX];
        int parent_fd, owned;

        posix_errno = resolve_target(target, component, sizeof(component),
                                     &name, &parent_fd, &owned);

        if(posix_errno != 0) {
            return posix_errno;
        }

        if(mkdirat(parent_fd, name, DIR_MODE) < 0) {
            posix_errno = errno;
        }

        if(owned) {
            close(parent_fd);
        }

        return posix_errno;
    }
#endif
}



posix_errno_t efile_del_at(efile_data_t *dir, const efile_path_t *path, int is_dir) {
#ifndef HAVE_UNLINKAT
    (void)dir;
    (void)path;
    (void)is_dir;

    return ENOTSUP;
#else
    efile_unix_t *u = (efile_unix_t*)dir;
    int flags;

    flags = is_dir ? AT_REMOVEDIR : 0;

    if(unlinkat(u->fd, (const char*)path->data, flags) < 0) {
        posix_errno_t saved_errno = errno;

        if(is_dir) {
            /* The path variant reports a directory that is not empty as
             * EEXIST, so this one does the same. */
            if(saved_errno == ENOTEMPTY) {
                saved_errno = EEXIST;
            }
        } else if(saved_errno == EISDIR) {
            /* Linux sets the wrong error code. */
            saved_errno = EPERM;
        }

        return saved_errno;
    }

    return 0;
#endif
}

posix_errno_t efile_del_file(const efile_path_t *path) {
    if(unlink((const char*)path->data) < 0) {
        /* Linux sets the wrong error code. */
        if(errno == EISDIR) {
            return EPERM;
        }

        return errno;
    }

    return 0;
}

posix_errno_t efile_del_dir(const efile_path_t *path) {
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
