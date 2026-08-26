<!--
%CopyrightBegin%

SPDX-License-Identifier: Apache-2.0

Copyright Ericsson AB 2023-2025. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

%CopyrightEnd%
-->
# Versions

[](){: #versions-section }

## OTP Version

As of OTP release 17, the OTP release number corresponds to the major part of
the OTP version. The OTP version as a concept was introduced in OTP 17. The
version scheme used is described in detail in
[Version Scheme](versions.md#version_scheme).

OTP of a specific version is a set of applications of specific versions. The
application versions identified by an OTP version correspond to application
versions that have been tested together by the Erlang/OTP team at Ericsson AB.
An OTP system can, however, be put together with applications from different OTP
versions. Such a combination of application versions has not been tested by the
Erlang/OTP team. It is therefore _always preferred to use OTP applications from
one single OTP version_.

Release candidates have an `-rc<N>` suffix. The suffix `-rc0` is used during
development up to the first release candidate.

### Retrieving Current OTP Version

In an OTP source code tree, the OTP version can be read from the text file
`<OTP source root>/OTP_VERSION`. The absolute path to the file can be
constructed by calling
`filename:join([`[`code:root_dir()`](`code:root_dir/0`)`, "OTP_VERSION"])`.

In an installed OTP development system, the OTP version can be read from the
text file `<OTP installation root>/releases/<OTP release number>/OTP_VERSION`.
The absolute path to the file can be constructed by calling
`filename:join([`[`code:root_dir()`](`code:root_dir/0`)`, "releases", `[`erlang:system_info(otp_release)`](`m:erlang#system_info_otp_release`)`, "OTP_VERSION"]).`

If the version read from the `OTP_VERSION` file in a development system has a
`**` suffix, the system has been patched using the
[`otp_patch_apply`](`e:system:otp-patch-apply.md`) tool. In this case, the
system consists of application versions from multiple OTP versions. The version
preceding the `**` suffix corresponds to the OTP version of the base system that
has been patched. Note that if a development system is updated by other means
than `otp_patch_apply`, the file `OTP_VERSION` can identify an incorrect OTP
version.

No `OTP_VERSION` file is placed in a [target system](create_target.md) created
by OTP tools, because one can easily create a target system where it is hard
to even determine the base OTP version. However, it is allowed to place such
a file there if one knows the OTP version.

### OTP Versions Table

The text file `<OTP source root>/otp_versions.table`, which is part of the
source code, contains information about all OTP versions from OTP 17.0 up to the
current OTP version. Each line contains information about application versions
that are part of a specific OTP version, and has the following format:

```text
<OtpVersion> : <ChangedAppVersions> # <UnchangedAppVersions> :
```

`<OtpVersion>` has the format `OTP-<VSN>`, that is, the same as the git tag used
to identify the source.

`<ChangedAppVersions>` and `<UnchangedAppVersions>` are space-separated lists of
application versions and have the format `<application>-<vsn>`.

- `<ChangedAppVersions>` corresponds to changed applications with new version
  numbers in this OTP version.
- `<UnchangedAppVersions>` corresponds to unchanged application versions in this
  OTP version.

Both of them can be empty, but not at the same time. If `<ChangedAppVersions>`
is empty, no changes have been made that change the build result of any
application. This could, for example, be a pure bug fix of the build system. The
order of lines is undefined. All white-space characters in this file are either
space (character 32) or line-break (character 10).

By using ordinary UNIX tools like `sed` and `grep` one can easily find answers
to various questions like:

- Which OTP versions are `kernel-3.0` part of?

  `$ grep ' kernel-3\.0 ' otp_versions.table`

- In which OTP version was `kernel-3.0` introduced?

  `$ sed 's/#.*//;/ kernel-3\.0 /!d' otp_versions.table`

The above commands give a bit more information than the exact answers, but
adequate information when manually searching for answers to these questions.

## Application Version

As of OTP 17.0 application versions use the same [version
scheme](versions.md#version_scheme) as the OTP version, except that
application versions never include the `-rc<N>` suffix. Also
note that a major increment in an application version does not
necessarily imply a major increment of the OTP version. This depends
on whether the major change in the application is considered a
major change for OTP as a whole or not.

[](){: #version_scheme }

## Version Scheme

> #### Change {: .info }
>
> The version scheme was changed as of OTP 17.0.
> [A list of application versions used in OTP 17.0](versions.md#otp_17_0_app_versions)
> is included at the end of this section.

Normally, a version is constructed as `<Major>.<Minor>.<Patch>`, where
`<Major>` is the most significant part. However, versions with more than three
dot-separated parts are possible.

The dot-separated parts consist of non-negative integers. If all parts
less significant than `<Minor>` equal `0`, they are omitted. The
three normal parts `<Major>.<Minor>.<Patch>` are changed as follows:

- `<Major>` - Increases when major changes, including incompatibilities, are
  made.
- `<Minor>` - Increases when new functionality is added.
- `<Patch>` - Increases when pure bug fixes are made.

When a part in the version number increases, all less significant parts are set
to `0`.

An application version or an OTP version identifies source code versions. That
is, it implies nothing about how the application or OTP has been built.

### Order of Versions

Version numbers in general are only **partially** ordered: for some pairs of
versions, neither is larger than the other. Comparing two versions therefore has
four possible outcomes: smaller, equal, larger, or **no order**.

Normal version numbers (with three parts or fewer) as of OTP 17.0 have a total
or linear order among themselves. This applies both to normal OTP versions and
normal application versions.

When comparing two version numbers with a defined order, one compares
each part as standard integers, starting from the most significant
part and moving towards the less significant parts. The order is
determined by the first parts of the same significance that differ. A
larger OTP version encompasses all changes present in a smaller OTP
version. The same principle applies to application versions.

#### Branched Versions

Versions can have more than three parts. Such versions are only used when
branching off from another version, and it is these that make the order partial.
When an extra part (apart from the normal three parts) is added to a version
number, a new branch of versions is made.

The **base** of a branched version is the version it was branched from: all of
its parts except the last. The version `6.0.2.1` is branched from the base
`6.0.2`. A version with three parts or fewer is not branched and is its own
base.

A branch exists to carry changes onto a release line that the main line has
already moved past. `6.0.2.1` includes everything in `6.0.2` plus the change it
was branched to deliver. `6.0.3` also includes everything in `6.0.2`, plus
different work. Neither includes all of the other, so neither is larger. They
have no order, and one can only conclude that both include what is in their
closest common ancestor.

A change made on a branch may or may not also be applied to the line the branch
left, and the version number does not record which. `6.0.3` may contain the fix
delivered in `6.0.2.1`, or it may not; nothing in either number says. This is
why the two have no order rather than an unknown-but-existing one, and why a
consumer must not infer that a change present in a branched version is present
in any later version off the base.

#### Comparing Two Versions

Branching is recursive: a branched version can itself be branched from, becoming
the base of the new branch. `18.3.4.1.1` is branched from `18.3.4.1`, which is
in turn branched from `18.3.4`.

To compare versions `A` and `B`, apply the first rule that matches:

1. **Neither has more than three parts.** They are ordered. Compare part by
   part as described above.
2. **One is an ancestor of the other**, that is, its parts are a leading
   sequence of the other's. The ancestor is the smaller: `18.3.4` < `18.3.4.1`
   < `18.3.4.1.1`.
3. **Both branch from the same base.** They are ordered by their differing
   last part: `6.0.2.1` < `6.0.2.2`.
4. **Exactly one has more than three parts**, and the other is smaller than or
   equal to a version the branched one descends from. The branched version is
   the larger: `6.0.1` < `6.0.2.1`, since `6.0.1` < `6.0.2`.
5. **Anything else.** They have **no order**.

Examples, taking `6.0.2.1` (branched from `6.0.2`) as the branched version:

| `A`         | `B`         | Result                            |
| ----------- | ----------- | --------------------------------- |
| `6.0.2`     | `6.0.2.1`   | `A` < `B` (rule 2, ancestor)      |
| `6.0.1`     | `6.0.2.1`   | `A` < `B` (rule 4, below base)    |
| `6.0.2.1`   | `6.0.2.2`   | `A` < `B` (rule 3, same base)     |
| `6.0.3`     | `6.0.2.1`   | **no order** (above the base)     |
| `6.1`       | `6.0.2.1`   | **no order** (above the base)     |
| `6.0.2.1`   | `6.0.3.1`   | **no order** (different bases)    |
| `6.0.2.0.1` | `6.0.2.1`   | **no order** (different bases)    |

Note the fourth and fifth rows: a normal version that *looks* larger than a
branched one is not larger, but unordered against it.

When branching multiple times from the same base version, `0` parts are added
between the base version and the least significant `1` part until a unique
version is found. A second branched version from the base version `6.0.2` will
be version `6.0.2.0.1`, and a third branched version will be `6.0.2.0.0.1`.
These branch from `6.0.2.0` and `6.0.2.0.0` respectively, not from `6.0.2`, so
they have no order against `6.0.2.1` or against each other, as the last row
above shows.

#### Sorting Is Not Comparing

A tool that lists versions must place every version somewhere, including pairs
this scheme leaves unordered. Such a placement is a presentation choice made by
that tool, not a statement about the versions.

Do not read a position in a sorted list as a claim about content. That
`6.0.2.1` is listed before `6.0.3` does not mean `6.0.3` includes its changes.
Only the comparison above establishes that one version encompasses another, and
only that comparison is a safe basis for deciding whether a fix is present in a
given version.

[](){: #releases_and_patches }

## Releases and Patches

When a new OTP release is released it will have an OTP version on the form
`<Major>.0` where the major OTP version number equals the release number. The
major version number is increased one step since the last major version. All
other OTP versions with the same major OTP version number are patches on that
OTP release.

Patches are either released as maintenance patch packages or emergency patch
packages. The only difference is that maintenance patch packages are planned and
usually contain more changes than emergency patch packages. Emergency patch
packages are released to solve one or more specific issues when such are
discovered.

The release of a maintenance patch package usually implies an increase
of the OTP `<Minor>` version, while the release of an emergency patch
package usually implies an increase of the OTP `<Patch>`
version. However, this is not always the case, as changes in OTP
versions are determined by actual code modifications rather than
whether the patch was planned or not. For more information see
[Version Scheme](versions.md#version_scheme).

[](){: #otp_versions_tree }

## OTP Versions Tree

All released OTP versions can be found in the [OTP Versions
Tree](http://www.erlang.org/download/otp_versions_tree.html), which is
automatically updated whenever we release a new OTP version. Note that
each version number explicitly determines its position in the version
tree. All that is required to build the tree are the version numbers
themselves.

The root of the tree is OTP version 17.0 which is when we introduced the new
[version scheme](versions.md#version_scheme). The green versions are normal
versions released on the main track. Old
[OTP releases](versions.md#releases_and_patches) will be maintained for a while
on `maint` branches that have branched off from the main track. Old `maint`
branches always branch off from the main track when the next OTP release is
introduced into the main track. Versions on these old `maint` branches are
marked blue.

Apart from the green and blue versions, there are also gray
versions. These denote versions established on branches to resolve a
particular issue for a specific customer based on a specific base
version. Branches with gray versions will typically become dead ends
very quickly if not immediately.

[](){: #otp_17_0_app_versions }

## OTP 17.0 Application Versions

The following list details the application versions that were part of
OTP 17.0.

If the normal part of an application version number is smaller than
the corresponding application version in the list, the version number
does not adhere to the versioning scheme introduced in OTP
17.0. Consequently, it is not regarded as having an order against
versions used from OTP 17.0 onwards.

- `asn1-3.0`
- `common_test-1.8`
- `compiler-5.0`
- `cosEvent-2.1.15`
- `cosEventDomain-1.1.14`
- `cosFileTransfer-1.1.16`
- `cosNotification-1.1.21`
- `cosProperty-1.1.17`
- `cosTime-1.1.14`
- `cosTransactions-1.2.14`
- `crypto-3.3`
- `debugger-4.0`
- `dialyzer-2.7`
- `diameter-1.6`
- `edoc-0.7.13`
- `eldap-1.0.3`
- `erl_docgen-0.3.5`
- `erl_interface-3.7.16`
- `erts-6.0`
- `et-1.5`
- `eunit-2.2.7`
- `gs-1.5.16`
- `hipe-3.10.3`
- `ic-4.3.5`
- `inets-5.10`
- `jinterface-1.5.9`
- `kernel-3.0`
- `megaco-3.17.1`
- `mnesia-4.12`
- `observer-2.0`
- `odbc-2.10.20`
- `orber-3.6.27`
- `os_mon-2.2.15`
- `ose-1.0`
- `otp_mibs-1.0.9`
- `parsetools-2.0.11`
- `percept-0.8.9`
- `public_key-0.22`
- `reltool-0.6.5`
- `runtime_tools-1.8.14`
- `sasl-2.4`
- `snmp-4.25.1`
- `ssh-3.0.1`
- `ssl-5.3.4`
- `stdlib-2.0`
- `syntax_tools-1.6.14`
- `test_server-3.7`
- `tools-2.6.14`
- `typer-0.9.6`
- `webtool-0.8.10`
- `wx-1.2`
- `xmerl-1.3.7`
