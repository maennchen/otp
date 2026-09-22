%%
%% %CopyrightBegin%
%%
%% SPDX-License-Identifier: Apache-2.0
%%
%% Copyright Ericsson AB 2000-2025. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%
-module(prim_file_SUITE).
-export([all/0, suite/0,groups/0,init_per_suite/1, end_per_suite/1, 
	 init_per_group/2,end_per_group/2, init_per_testcase/2, end_per_testcase/2,
	 read_write_file/1, free_memory/0]).
-export([cur_dir_0/1, cur_dir_1/1,
	 make_del_dir/1, pos1/1, pos2/1]).
-export([close/1, delete/1]).
-export([open1/1, modes/1]).
-export([file_info_basic_file/1, file_info_basic_directory/1, file_info_bad/1,
	 file_info_times/1, file_write_file_info/1,
         file_read_file_info_opts/1, file_write_file_info_opts/1,
	 file_write_read_file_info_opts/1]).
-export([rename/1, access/1, truncate/1, datasync/1, sync/1,
	 read_write/1, pread_write/1, append/1, exclusive/1,
	 read_file_rename_race/1]).
-export([e_delete/1, e_rename/1, e_make_dir/1, e_del_dir/1]).

-export([make_link/1, read_link_info_for_non_link/1,
	 symlinks/1,
	 list_dir_limit/1,
	 list_dir_error/1,
	 list_dir/1,
	 list_dir_handle/1]).

-export([open_at/1, read_at/1, write_at/1, link_at/1, open_in_root/1,
         resolve_in_root/1, open_root/1, dup/1]).

-export([file_write_handle_info/1]).

-export([adopt/1]).

-export([advise/1]).
-export([large_write/1]).

%% System probe functions that might be handy to check from the shell
-export([unix_free/1]).

-export([allocate/1]).

-include_lib("common_test/include/ct.hrl").
-include_lib("kernel/include/file.hrl").

-define(PRIM_FILE, prim_file).

suite() -> [].

all() -> 
    [read_write_file, {group, dirs}, {group, files},
     delete, rename, {group, errors}, {group, links},
     list_dir_limit, list_dir, list_dir_handle, adopt, open_at, read_at,
     write_at, link_at, open_in_root, resolve_in_root, open_root, dup].

groups() -> 
    [{dirs, [],
      [make_del_dir, cur_dir_0, cur_dir_1]},
     {files, [],
      [{group, open}, {group, pos}, {group, file_info},
       truncate, sync, datasync, advise, large_write, allocate]},
     {open, [],
      [open1, modes, close, access, read_write, pread_write,
       append, exclusive, read_file_rename_race]},
     {pos, [], [pos1, pos2]},
     {file_info, [],
      [file_info_basic_file,file_info_basic_directory, file_info_bad,
       file_info_times, file_write_file_info, file_read_file_info_opts,
       file_write_file_info_opts, file_write_read_file_info_opts,
       file_write_handle_info
      ]},
     {errors, [],
      [e_delete, e_rename, e_make_dir, e_del_dir]},
     {links, [],
      [make_link, read_link_info_for_non_link, symlinks, list_dir_error]}].

init_per_testcase(large_write, Config) ->
    {ok, Started} = application:ensure_all_started(os_mon),
    [{started, Started}|Config];
init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(large_write, Config) ->
    [application:stop(App) || App <- lists:reverse(proplists:get_value(started, Config))],
    ok;
end_per_testcase(_, _Config) ->
    ok.

init_per_group(_GroupName, Config) ->
    Config.

end_per_group(_GroupName, Config) ->
    Config.


init_per_suite(Config) when is_list(Config) ->
    case os:type() of
	{win32, _} ->
	    Priv = proplists:get_value(priv_dir, Config),
	    HasAccessTime =
		case file:read_file_info(Priv) of
		    {ok, #file_info{atime={_, {0, 0, 0}}}} ->
			%% This is a unfortunately a FAT file system.
			[no_access_time];
		    {ok, _} ->
			[]
		end,
	    HasAccessTime++Config;
	_ ->
	    Config
    end.

end_per_suite(Config) when is_list(Config) ->
    case os:type() of
	{win32, _} ->
	    os:cmd("subst z: /d");
	_ ->
	    ok
    end,
    Config.

%% Matches a term (the last) against alternatives
expect(X, _, X) ->
    X;
expect(_, X, X) ->
    X.

expect(X, _, _, X) ->
    X;
expect(_, X, _, X) ->
    X;
expect(_, _, X, X) ->
    X.

expect(X, _, _, _, X) ->
    X;
expect(_, X, _, _, X) ->
    X;
expect(_, _, X, _, X) ->
    X;
expect(_, _, _, X, X) ->
    X.

%% Calculate the time difference
time_dist({YY, MM, DD, H, M, S}, DT) ->
    time_dist({{YY, MM, DD}, {H, M, S}}, DT);
time_dist(DT, {YY, MM, DD, H, M, S}) ->
    time_dist(DT, {{YY, MM, DD}, {H, M, S}});
time_dist({_D1, _T1} = DT1, {_D2, _T2} = DT2) ->
    calendar:datetime_to_gregorian_seconds(DT2)
	- calendar:datetime_to_gregorian_seconds(DT1).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

read_write_file(Config) when is_list(Config) ->
    RootDir = proplists:get_value(priv_dir,Config),
    Name = filename:join(RootDir,
			 atom_to_list(?MODULE)
			 ++"_read_write_file"),

    %% Try writing and reading back some term
    SomeTerm = {"This term",{will,be},[written,$t,$o],1,file,[]},
    ok = ?PRIM_FILE:write_file(Name,term_to_binary(SomeTerm)),
    {ok,Bin1} = ?PRIM_FILE:read_file(Name),
    SomeTerm = binary_to_term(Bin1),

    %% Try a "null" term
    NullTerm = [],
    ok = ?PRIM_FILE:write_file(Name,term_to_binary(NullTerm)),
    {ok,Bin2} = ?PRIM_FILE:read_file(Name),
    NullTerm = binary_to_term(Bin2),

    %% Try some "complicated" types
    BigNum = 123456789012345678901234567890,
    ComplTerm = {self(),make_ref(),BigNum,3.14159},
    ok = ?PRIM_FILE:write_file(Name,term_to_binary(ComplTerm)),
    {ok,Bin3} = ?PRIM_FILE:read_file(Name),
    ComplTerm = binary_to_term(Bin3),

    %% Try reading a nonexistent file
    Name2 = filename:join(RootDir,
			  atom_to_list(?MODULE)
			  ++"_nonexistent_file"),
    {error, enoent} = ?PRIM_FILE:read_file(Name2),
    {error, enoent} = ?PRIM_FILE:read_file(""),

    %% Try writing to a bad filename
    {error, enoent} =
	?PRIM_FILE:write_file("",term_to_binary(NullTerm)),

    %% Try writing something else than a binary
    {error, badarg} = ?PRIM_FILE:write_file(Name,{1,2,3}),
    {error, badarg} = ?PRIM_FILE:write_file(Name,self()),

    %% Some non-term binaries
    ok = ?PRIM_FILE:write_file(Name,[]),
    {ok,Bin4} = ?PRIM_FILE:read_file(Name),
    0 = byte_size(Bin4),

    ok = ?PRIM_FILE:write_file(Name,[Bin1,[],[[Bin2]]]),
    {ok,Bin5} = ?PRIM_FILE:read_file(Name),
    {Bin1,Bin2} = split_binary(Bin5,byte_size(Bin1)),

    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

make_del_dir(Config) when is_list(Config) ->
    RootDir = proplists:get_value(priv_dir,Config),
    NewDir = filename:join(RootDir,
			   atom_to_list(?MODULE)
			   ++"_mk-dir"),
    ok = ?PRIM_FILE:make_dir(NewDir),
    {error, eexist} = ?PRIM_FILE:make_dir(NewDir),
    ok = ?PRIM_FILE:del_dir(NewDir),
    {error, enoent} = ?PRIM_FILE:del_dir(NewDir),

    %% Make sure we are not in a directory directly under test_server
    %% as that would result in eacces errors when trying to delete '..',
    %% because there are processes having that directory as current.
    ok = ?PRIM_FILE:make_dir(NewDir),
    {ok, CurrentDir} = ?PRIM_FILE:get_cwd(),
    case {os:type(), length(NewDir) >= 260 } of
	{{win32,_}, true} ->
	    io:format("Skip set_cwd for windows path longer than 260 (MAX_PATH)\n", []),
	    io:format("\nNewDir = ~p\n", [NewDir]);
	_ ->
	    ok = ?PRIM_FILE:set_cwd(NewDir)
    end,
    try
	%% Check that we get an error when trying to create...
	%% a deep directory
	NewDir2 = filename:join(RootDir,
				atom_to_list(?MODULE)
				++"_mk-dir-noexist/foo"),
	{error, enoent} = ?PRIM_FILE:make_dir(NewDir2),
	%% a nameless directory
	{error, enoent} = ?PRIM_FILE:make_dir(""),
	%% a directory with illegal name
	{error, badarg} = ?PRIM_FILE:make_dir('mk-dir'),

	%% a directory with illegal name, even if it's a (bad) list
	{error, badarg} = ?PRIM_FILE:make_dir([1,2,3,{}]),

	%% Maybe this isn't an error, exactly, but worth mentioning anyway:
	%% ok = ?PRIM_FILE:make_dir([$f,$o,$o,0,$b,$a,$r])),
	%% The above line works, and created a directory "./foo"
	%% More elegant would maybe have been to fail, or to really create
	%% a directory, but with a name that incorporates the "bar" part of
	%% the list, so that [$f,$o,$o,0,$f,$o,$o] wouldn't refer to the same
	%% dir. But this would slow it down.

	%% Try deleting some bad directories
	%% Deleting the parent directory to the current, sounds dangerous, huh?
	%% Don't worry ;-) the parent directory should never be empty, right?
	case ?PRIM_FILE:del_dir("..") of
	    {error, eexist} -> ok;
	    {error, eacces} -> ok;	%OpenBSD
	    {error, einval} -> ok		%FreeBSD
	end,
	{error, enoent} = ?PRIM_FILE:del_dir(""),
	{error, badarg} = ?PRIM_FILE:del_dir([3,2,1,{}])
    after
	ok = ?PRIM_FILE:set_cwd(CurrentDir)
    end,
    ok.

cur_dir_0(Config) when is_list(Config) ->
    %% Find out the current dir, and cd to it ;-)
    {ok,BaseDir} = ?PRIM_FILE:get_cwd(),
    Dir1 = BaseDir ++ "", %% Check that it's a string
    ok = ?PRIM_FILE:set_cwd(Dir1),
    DirName = atom_to_list(?MODULE) ++ "_curdir",

    %% Make a new dir, and cd to that
    RootDir = proplists:get_value(priv_dir,Config),
    NewDir = filename:join(RootDir, DirName),
    ok = ?PRIM_FILE:make_dir(NewDir),
    case {os:type(), length(NewDir) >= 260} of
	{{win32,_}, true} ->
	    io:format("Skip set_cwd for windows path longer than 260 (MAX_PATH):\n"),
	    io:format("\nNewDir = ~p\n", [NewDir]);
	_ ->
	    io:format("cd to ~s",[NewDir]),
	    ok = ?PRIM_FILE:set_cwd(NewDir),

	    %% Create a file in the new current directory, and check that it
	    %% really is created there
	    UncommonName = "uncommon.fil",
	    {ok,Fd} = ?PRIM_FILE:open(UncommonName, [read, write]),
	    ok = ?PRIM_FILE:close(Fd),
	    {ok,NewDirFiles} = ?PRIM_FILE:list_dir("."),
	    true = lists:member(UncommonName,NewDirFiles),

	    %% Delete the directory and return to the old current directory
	    %% and check that the created file isn't there (too!)
	    expect({error, einval}, {error, eacces}, {error, eexist},
		   ?PRIM_FILE:del_dir(NewDir)),
	    ?PRIM_FILE:delete(UncommonName),
	    {ok,[]} = ?PRIM_FILE:list_dir("."),
	    ok = ?PRIM_FILE:set_cwd(Dir1),
	    io:format("cd back to ~s",[Dir1]),
	    ok = ?PRIM_FILE:del_dir(NewDir),
	    {error, enoent} = ?PRIM_FILE:set_cwd(NewDir),
	    ok = ?PRIM_FILE:set_cwd(Dir1),
	    io:format("cd back to ~s",[Dir1]),
	    {ok,OldDirFiles} = ?PRIM_FILE:list_dir("."),
	    false = lists:member(UncommonName,OldDirFiles)
    end,

    %% Try doing some bad things
    {error, badarg} =
	?PRIM_FILE:set_cwd({foo,bar}),
    {error, enoent} =
	?PRIM_FILE:set_cwd(""),
    {error, enoent} =
	?PRIM_FILE:set_cwd(".......a......"),
    {ok,BaseDir} =
	?PRIM_FILE:get_cwd(), %% Still there?

    %% On Windows, there should only be slashes, no backslashes,
    %% in the return value of get_cwd().
    %% (The test is harmless on Unix, because filenames usually
    %% don't contain backslashes.)

    {ok, BaseDir} = ?PRIM_FILE:get_cwd(),
    false = lists:member($\\, BaseDir),

    ok.

%% Tests ?PRIM_FILE:get_cwd/1.

cur_dir_1(Config) when is_list(Config) ->
    case os:type() of
	{win32, _} ->
	    win_cur_dir_1(Config);
	_ ->
	    {error, enotsup} =
		?PRIM_FILE:get_cwd("d:")
    end,
    ok.

win_cur_dir_1(_Config) ->
    {ok, BaseDir} = ?PRIM_FILE:get_cwd(),

    %% Get the drive letter from the current directory,
    %% and try to get current directory for that drive.

    [Drive, $:|_] = BaseDir,
    {ok, BaseDir} = ?PRIM_FILE:get_cwd([Drive, $:]),
    io:format("BaseDir = ~s\n", [BaseDir]),

    %% Unfortunately, there is no way to move away from the
    %% current drive as we can't use the "subst" command from
    %% a SSH connection. We can't test any more. Too bad.

    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%



open1(Config) when is_list(Config) ->
    RootDir = proplists:get_value(priv_dir,Config),
    NewDir = filename:join(RootDir,
			   atom_to_list(?MODULE)
			   ++"_files"),
    ok = ?PRIM_FILE:make_dir(NewDir),
    Name = filename:join(NewDir, "foo1.fil"),
    {ok,Fd1} = ?PRIM_FILE:open(Name, [read, write]),
    {ok,Fd2} = ?PRIM_FILE:open(Name, [read]),
    Bin = list_to_binary("{a,tuple}.\n"),
    Length = byte_size(Bin),
    ?PRIM_FILE:write(Fd1,Bin),
    {ok,0} = ?PRIM_FILE:position(Fd1,bof),
    {ok, Bin} = ?PRIM_FILE:read(Fd1,Length),
    {ok, Bin} = ?PRIM_FILE:read(Fd2,Length),
    ok = ?PRIM_FILE:close(Fd2),
    {ok,0} = ?PRIM_FILE:position(Fd1,bof),
    ok = ?PRIM_FILE:truncate(Fd1),
    eof = ?PRIM_FILE:read(Fd1,Length),
    ok = ?PRIM_FILE:close(Fd1),
    {ok,Fd3} = ?PRIM_FILE:open(Name, [read]),
    eof = ?PRIM_FILE:read(Fd3,Length),
    ok = ?PRIM_FILE:close(Fd3),
    ok.

%% Tests all open modes.

modes(Config) when is_list(Config) ->
    RootDir = proplists:get_value(priv_dir, Config),
    NewDir = filename:join(RootDir,
			   atom_to_list(?MODULE)
			   ++"_open_modes"),
    ok = ?PRIM_FILE:make_dir(NewDir),
    Name1 = filename:join(NewDir, "foo1.fil"),
    Marker = <<"hello, world">>,
    Length = byte_size(Marker),

    %% write
    {ok, Fd1} = ?PRIM_FILE:open(Name1, [write]),
    ok = ?PRIM_FILE:write(Fd1, Marker),
    ok = ?PRIM_FILE:write(Fd1, <<".\n">>),
    ok = ?PRIM_FILE:close(Fd1),

    %% read
    {ok, Fd2} = ?PRIM_FILE:open(Name1, [read]),
    {ok, Marker} = ?PRIM_FILE:read(Fd2, Length),
    ok = ?PRIM_FILE:close(Fd2),

    %% read and write
    {ok, Fd3} = ?PRIM_FILE:open(Name1, [read, write]),
    {ok, Marker} = ?PRIM_FILE:read(Fd3, Length),
    ok = ?PRIM_FILE:write(Fd3, Marker),
    ok = ?PRIM_FILE:close(Fd3),

    %% read by default
    {ok, Fd4} = ?PRIM_FILE:open(Name1, []),
    {ok, Marker} = ?PRIM_FILE:read(Fd4, Length),
    ok = ?PRIM_FILE:close(Fd4),

    ok.

close(Config) when is_list(Config) ->
    RootDir = proplists:get_value(priv_dir,Config),
    Name = filename:join(RootDir,
			 atom_to_list(?MODULE)
			 ++"_close.fil"),
    {ok,Fd1} = ?PRIM_FILE:open(Name, [read, write]),
    %% Just closing it is no fun, we did that a million times already
    %% This is a common error, for code written before Erlang 4.3
    %% because then ?PRIM_FILE:open just returned a Pid, and not everyone
    %% really checked what they got.
    {'EXIT',_Msg} = (catch ok = ?PRIM_FILE:close({ok,Fd1})),
    ok = ?PRIM_FILE:close(Fd1),

    %% Try closing one more time
    Val = ?PRIM_FILE:close(Fd1),
    io:format("Second close gave: ~p", [Val]),

    ok.

access(Config) when is_list(Config) ->
    RootDir = proplists:get_value(priv_dir,Config),
    Name = filename:join(RootDir,
			 atom_to_list(?MODULE)
			 ++"_access.fil"),
    Bin = <<"ABCDEFGH">>,
    {ok,Fd1} = ?PRIM_FILE:open(Name, [write]),
    ?PRIM_FILE:write(Fd1,Bin),
    ok = ?PRIM_FILE:close(Fd1),
    %% Check that we can't write when in read only mode
    {ok,Fd2} = ?PRIM_FILE:open(Name, [read]),
    case catch ?PRIM_FILE:write(Fd2,"XXXX") of
	ok ->
	    ct:fail({access,write});
	_ ->
	    ok
    end,
    ok = ?PRIM_FILE:close(Fd2),
    {ok, Fd3} = ?PRIM_FILE:open(Name, [read]),
    {ok, Bin} = ?PRIM_FILE:read(Fd3,byte_size(Bin)),
    ok = ?PRIM_FILE:close(Fd3),

    ok.

%% Tests ?PRIM_FILE:read/2 and ?PRIM_FILE:write/2.

read_write(Config) when is_list(Config) ->
    RootDir = proplists:get_value(priv_dir, Config),
    NewDir = filename:join(RootDir,
			   atom_to_list(?MODULE)
			   ++"_read_write"),
    ok = ?PRIM_FILE:make_dir(NewDir),

    %% Raw file.
    Name = filename:join(NewDir, "raw.fil"),
    {ok, Fd} = ?PRIM_FILE:open(Name, [read, write]),
    read_write_test(Fd),

    ok.

read_write_test(File) ->
    Marker = <<"hello, world">>,
    ok = ?PRIM_FILE:write(File, Marker),
    {ok, 0} = ?PRIM_FILE:position(File, 0),
    {ok, Marker} = ?PRIM_FILE:read(File, 100),
    eof = ?PRIM_FILE:read(File, 100),
    ok = ?PRIM_FILE:close(File),
    ok.


%% Tests ?PRIM_FILE:pread/2 and ?PRIM_FILE:pwrite/2.

pread_write(Config) when is_list(Config) ->
    RootDir = proplists:get_value(priv_dir, Config),
    NewDir = filename:join(RootDir,
			   atom_to_list(?MODULE)
			   ++"_pread_write"),
    ok = ?PRIM_FILE:make_dir(NewDir),

    %% Raw file.
    Name = filename:join(NewDir, "raw.fil"),
    {ok, Fd} = ?PRIM_FILE:open(Name, [read, write]),
    pread_write_test(Fd),

    ok.

pread_write_test(File) ->
    Marker = <<"hello, world">>,
    Len = byte_size(Marker),
    ok = ?PRIM_FILE:write(File, Marker),
    {ok, Marker} = ?PRIM_FILE:pread(File, 0, 100),
    eof = ?PRIM_FILE:pread(File, 100, 1),
    ok = ?PRIM_FILE:pwrite(File, Len, Marker),
    {ok, Marker} = ?PRIM_FILE:pread(File, Len, 100),
    eof = ?PRIM_FILE:pread(File, 100, 1),
    MM = <<Marker/binary,Marker/binary>>,
    {ok, MM} = ?PRIM_FILE:pread(File, 0, 100),
    ok = ?PRIM_FILE:close(File),
    ok.

%% Test appending to a file.
append(Config) when is_list(Config) ->
    RootDir = proplists:get_value(priv_dir, Config),
    NewDir = filename:join(RootDir,
			   atom_to_list(?MODULE)
			   ++"_append"),
    ok = ?PRIM_FILE:make_dir(NewDir),

    First = "First line\n",
    Second = "Second lines comes here\n",
    Third = "And here is the third line\n",

    %% Write a small text file.
    Name1 = filename:join(NewDir, "a_file.txt"),
    {ok, Fd1} = ?PRIM_FILE:open(Name1, [write]),
    ok = ?PRIM_FILE:write(Fd1, First),
    ok = ?PRIM_FILE:write(Fd1, Second),
    ok = ?PRIM_FILE:close(Fd1),

    %% Open it a again and a append a line to it.
    {ok, Fd2} = ?PRIM_FILE:open(Name1, [append]),
    ok = ?PRIM_FILE:write(Fd2, Third),
    ok = ?PRIM_FILE:close(Fd2),

    %% Read it back and verify.
    Expected = list_to_binary([First, Second, Third]),
    {ok, Expected} = ?PRIM_FILE:read_file(Name1),

    ok.

%% Test exclusive access to a file.
exclusive(Config) when is_list(Config) ->
    RootDir = proplists:get_value(priv_dir,Config),
    NewDir = filename:join(RootDir,
			   atom_to_list(?MODULE)
			   ++"_exclusive"),
    ok = ?PRIM_FILE:make_dir(NewDir),
    Name = filename:join(NewDir, "ex_file.txt"),
    {ok,Fd} = ?PRIM_FILE:open(Name, [write, exclusive]),
    {error, eexist} = ?PRIM_FILE:open(Name, [write, exclusive]),
    ok = ?PRIM_FILE:close(Fd),
    ok.

%% Test read_file with concurrent renames and size changes.

-define(RFRR_DATA1, <<"gazonk">>).
-define(RFRR_DATA2, <<"fubar">>). % shorter than and not a prefix of DATA1

read_file_rename_race(Config) when is_list(Config) ->
    %% This test reportedly fails on Windows and Darwin 9.8.0.
    Supported =
	case os:type() of
	    {win32, _} -> false;
	    {unix, darwin} -> os:version() > {9,8,0};
	    {unix, _} -> true
	end,
    if Supported ->
	Dir = proplists:get_value(priv_dir, Config),
	Name = filename:join(Dir, "filename"),
	rfrr_write_file(Name, ?RFRR_DATA2),
	Mutator = spawn_link(fun() -> rfrr_mutator(Name, ?RFRR_DATA1, ?RFRR_DATA2) end),
	Result = rfrr_reader(Name, 1, _N = 5000),
	unlink(Mutator),
	exit(Mutator, kill),
	ok = Result;
       true ->
	{skipped, "Not supported on Windows, or Darwin =< 9.8.0"}
    end.

rfrr_reader(Name, I, N) when I < N ->
    case rfrr_read_file(Name, I) of
	ok -> rfrr_reader(Name, I + 1, N);
	error -> error
    end;
rfrr_reader(_Name, _I, _N) -> ok.

rfrr_read_file(Name, I) ->
    case prim_file:read_file(Name) of
	{ok, ?RFRR_DATA1} -> ok;
	{ok, ?RFRR_DATA2} -> ok;
	Other ->
	    io:format(standard_error, "rfrr_read_file #~p got ~p\n", [I, Other]),
	    error
    end.

%% Correctness of read_file must not depend on the mutator using the
%% file server in the reader's Erlang VM, so we use prim_file here.
rfrr_mutator(Name, Data1, Data2) ->
    rfrr_write_file(Name, Data1),
    rfrr_mutator(Name, Data2, Data1).

%% Atomically replace Name with a new file containing Data.
rfrr_write_file(Name, Data) ->
    NameTmp = Name ++ ".tmp", % must be in same volume as Name
    ok = prim_file:write_file(NameTmp, Data),
    ok = prim_file:rename(NameTmp, Name).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


pos1(Config) when is_list(Config) ->
    RootDir = proplists:get_value(priv_dir,Config),
    Name = filename:join(RootDir,
			 atom_to_list(?MODULE)
			 ++"_pos1.fil"),
    {ok, Fd1} = ?PRIM_FILE:open(Name, [write]),
    ?PRIM_FILE:write(Fd1,<<"ABCDEFGH">>),
    ok        = ?PRIM_FILE:close(Fd1),
    {ok, Fd2} = ?PRIM_FILE:open(Name, [read]),

    %% Start pos is first char
    io:format("Relative positions"),
    {ok, <<"A">>} = ?PRIM_FILE:read(Fd2,1),
    {ok, 2}   = ?PRIM_FILE:position(Fd2,{cur,1}),
    {ok, <<"C">>} = ?PRIM_FILE:read(Fd2,1),
    {ok, 0}   = ?PRIM_FILE:position(Fd2,{cur,-3}),
    {ok, <<"A">>} = ?PRIM_FILE:read(Fd2,1),
    %% Backwards from first char should be an error
    {ok,0}    = ?PRIM_FILE:position(Fd2,{cur,-1}),
    {error, einval} = ?PRIM_FILE:position(Fd2,{cur,-1}),
    %% Reset position and move again
    {ok, 0}   = ?PRIM_FILE:position(Fd2,0),
    {ok, 2}   = ?PRIM_FILE:position(Fd2,{cur,2}),
    {ok, <<"C">>} = ?PRIM_FILE:read(Fd2,1),
    %% Go a lot forwards
    {ok, 13}  = ?PRIM_FILE:position(Fd2,{cur,10}),
    eof       = ?PRIM_FILE:read(Fd2,1),

    %% Try some fixed positions
    io:format("Fixed positions"),
    {ok, 8}   = ?PRIM_FILE:position(Fd2,8),
    eof = ?PRIM_FILE:read(Fd2,1),
    {ok, 8}   = ?PRIM_FILE:position(Fd2,cur),
    eof = ?PRIM_FILE:read(Fd2,1),
    {ok, 7}   = ?PRIM_FILE:position(Fd2,7),
    {ok, <<"H">>} = ?PRIM_FILE:read(Fd2,1),
    {ok, 0}   = ?PRIM_FILE:position(Fd2,0),
    {ok, <<"A">>} = ?PRIM_FILE:read(Fd2,1),
    {ok, 3}   = ?PRIM_FILE:position(Fd2,3),
    {ok, <<"D">>} = ?PRIM_FILE:read(Fd2,1),
    {ok, 12}  = ?PRIM_FILE:position(Fd2,12),
    eof       = ?PRIM_FILE:read(Fd2,1),
    {ok, 3}   = ?PRIM_FILE:position(Fd2,3),
    {ok, <<"D">>} = ?PRIM_FILE:read(Fd2,1),
    %% Try the {bof,X} notation
    {ok, 3}   = ?PRIM_FILE:position(Fd2,{bof,3}),
    {ok, <<"D">>} = ?PRIM_FILE:read(Fd2,1),

    %% Try eof positions
    io:format("EOF positions"),
    {ok, 8}   = ?PRIM_FILE:position(Fd2,{eof,0}),
    eof       = ?PRIM_FILE:read(Fd2,1),
    {ok, 7}   = ?PRIM_FILE:position(Fd2,{eof,-1}),
    {ok, <<"H">>} = ?PRIM_FILE:read(Fd2,1),
    {ok, 0}   = ?PRIM_FILE:position(Fd2,{eof,-8}),
    {ok, <<"A">>} = ?PRIM_FILE:read(Fd2,1),
    {error, einval} = ?PRIM_FILE:position(Fd2,{eof,-9}),
    ok.

pos2(Config) when is_list(Config) ->
    RootDir = proplists:get_value(priv_dir,Config),
    Name = filename:join(RootDir,
			 atom_to_list(?MODULE)
			 ++"_pos2.fil"),
    {ok,Fd1} = ?PRIM_FILE:open(Name, [write]),
    ?PRIM_FILE:write(Fd1,<<"ABCDEFGH">>),
    ok = ?PRIM_FILE:close(Fd1),
    {ok, Fd2} = ?PRIM_FILE:open(Name, [read]),
    {error, einval} = ?PRIM_FILE:position(Fd2,-1),

    %% Make sure that we still can search after an error.
    {ok, 0}   = ?PRIM_FILE:position(Fd2, 0),
    {ok, 3}   = ?PRIM_FILE:position(Fd2, {bof,3}),
    {ok, <<"D">>} = ?PRIM_FILE:read(Fd2,1),

    io:format("DONE"),
    ok.

file_info_basic_file(Config) when is_list(Config) ->
    RootDir = proplists:get_value(priv_dir, Config),

    %% Create a short file.
    Name = filename:join(RootDir,
			 atom_to_list(?MODULE)
			 ++"_basic_test.fil"),
    {ok,Fd1} = ?PRIM_FILE:open(Name, [write]),
    ?PRIM_FILE:write(Fd1, "foo bar"),
    ok = ?PRIM_FILE:close(Fd1),

    %% Test that the file has the expected attributes.
    %% The times are tricky, so we will save them to a separate test case.
    {ok, FileInfo} = ?PRIM_FILE:read_file_info(Name),
    #file_info{size = Size, type = Type, access = Access,
	       atime = AccessTime, mtime = ModifyTime} =
	FileInfo,
    io:format("Access ~p, Modify ~p", [AccessTime, ModifyTime]),
    Size = 7,
    Type = regular,
    Access = read_write,
    true = abs(time_dist(filter_atime(AccessTime, Config),
			 filter_atime(ModifyTime,
				      Config))) < 2,
    {AD, AT} = AccessTime,
    all_integers(tuple_to_list(AD) ++ tuple_to_list(AT)),
    {MD, MT} = ModifyTime,
    all_integers(tuple_to_list(MD) ++ tuple_to_list(MT)),

    ok.

file_info_basic_directory(Config) when is_list(Config) ->
    %% Note: filename:join/1 removes any trailing slash,
    %% which is essential for ?PRIM_FILE:read_file_info/1 to work on
    %% platforms such as Windows95.
    RootDir = filename:join([proplists:get_value(priv_dir, Config)]),

    %% Test that the RootDir directory has the expected attributes.
    test_directory(RootDir, read_write),

    %% Note that on Windows file systems, "/" or "c:/" are *NOT* directories.
    %% Therefore, test that ?PRIM_FILE:read_file_info/1 behaves 
    %% as if they were directories.
    case os:type() of
	{win32, _} ->
	    test_directory("/", read_write),
	    test_directory("c:/", read_write),
	    test_directory("c:\\", read_write);
	_ ->
	    test_directory("/", read)
    end,
    ok.

test_directory(Name, ExpectedAccess) ->
    {ok, FileInfo} = ?PRIM_FILE:read_file_info(Name),
    #file_info{size = Size, type = Type, access = Access,
	       atime = AccessTime, mtime = ModifyTime} =
	FileInfo,
    io:format("Testing directory ~s", [Name]),
    io:format("Directory size is ~p", [Size]),
    io:format("Access ~p", [Access]),
    io:format("Access time ~p; Modify time~p",
	      [AccessTime, ModifyTime]),
    Type = directory,
    Access = ExpectedAccess,
    {AD, AT} = AccessTime,
    all_integers(tuple_to_list(AD) ++ tuple_to_list(AT)),
    {MD, MT} = ModifyTime,
    all_integers(tuple_to_list(MD) ++ tuple_to_list(MT)),
    ok.

all_integers([Int|Rest]) when is_integer(Int) ->
    all_integers(Rest);
all_integers([]) ->
    ok.

%% Try something nonexistent.

file_info_bad(Config) when is_list(Config) ->
    RootDir = filename:join([proplists:get_value(priv_dir, Config)]),
    NonExistent = filename:join(RootDir, atom_to_list(?MODULE)++"_nonexistent"),
    {error, enoent} = ?PRIM_FILE:read_file_info(NonExistent),
    ok.

%% Test that the file times behave as they should.

file_info_times(Config) when is_list(Config) ->
    %% We have to try this twice, since if the test runs across the change
    %% of a month the time diff calculations will fail. But it won't happen
    %% if you run it twice in succession.
    test_server:m_out_of_n(
      1,2,
      fun() -> file_info_int(Config) end),
    ok.

file_info_int(Config) ->
    %% Note: filename:join/1 removes any trailing slash,
    %% which is essential for ?PRIM_FILE:read_file_info/1 to work on
    %% platforms such as Windows95.

    RootDir = filename:join([proplists:get_value(priv_dir, Config)]),
    io:format("RootDir = ~p", [RootDir]),

    Name = filename:join(RootDir,
			 atom_to_list(?MODULE)
			 ++"_file_info.fil"),
    {ok,Fd1} = ?PRIM_FILE:open(Name, [write]),
    ?PRIM_FILE:write(Fd1,"foo"),

    %% check that the file got a modify date max a few seconds away from now
    {ok, #file_info{type = regular,
		    atime = AccTime1, mtime = ModTime1}} =
	?PRIM_FILE:read_file_info(Name),
    Now = erlang:localtime(),
    io:format("Now ~p",[Now]),
    io:format("Open file Acc ~p Mod ~p",[AccTime1,ModTime1]),
    true = abs(time_dist(filter_atime(Now, Config),
			 filter_atime(AccTime1,
				      Config))) < 8,
    true = abs(time_dist(Now, ModTime1)) < 8,

    %% Sleep until we can be sure the seconds value has changed.
    %% Note: FAT-based filesystem (like on Windows 95) have
    %% a resolution of 2 seconds.
    ct:sleep({seconds,2.2}),

    %% close the file, and watch the modify date change
    ok = ?PRIM_FILE:close(Fd1),
    {ok, #file_info{size = Size, type = regular, access = Access,
		    atime = AccTime2, mtime = ModTime2}} =
	?PRIM_FILE:read_file_info(Name),
    io:format("Closed file Acc ~p Mod ~p",[AccTime2,ModTime2]),
    true = time_dist(ModTime1, ModTime2) >= 0,

    %% this file is supposed to be binary, so it'd better keep it's size
    Size = 3,
    Access = read_write,

    %% Do some directory checking
    {ok, #file_info{size = DSize, type = directory,
		    access = DAccess,
		    atime = AccTime3, mtime = ModTime3}} =
	?PRIM_FILE:read_file_info(RootDir),
    %% this dir was modified only a few secs ago
    io:format("Dir Acc ~p; Mod ~p; Now ~p",
	      [AccTime3, ModTime3, Now]),
    true = abs(time_dist(Now, ModTime3)) < 5,
    DAccess = read_write,
    io:format("Dir size is ~p",[DSize]),
    ok.

%% Filter access times, to cope with a deficiency of FAT file systems
%% (on Windows): The access time is actually only a date.

filter_atime(Atime, Config) ->
    case lists:member(no_access_time, Config) of
	true ->
	    case Atime of
	    	{Date, _} ->
		    {Date, {0, 0, 0}};
		{Y, M, D, _, _, _} ->
		    {Y, M, D, 0, 0, 0}
	    end;
	false ->
	    Atime
    end.

%% Test the write_file_info/2 function.

file_write_file_info(Config) when is_list(Config) ->
    RootDir = get_good_directory(Config),
    io:format("RootDir = ~p", [RootDir]),

    %% Set the file to read only AND update the file times at the same time.
    %% (This used to fail on Windows NT/95 for a local filesystem.)
    %% Note: Seconds must be even; see note in file_info_times/1.

    Name = filename:join(RootDir,
			 atom_to_list(?MODULE)
			 ++"_write_file_info_ro"),
    ok = ?PRIM_FILE:write_file(Name, "hello"),
    Time = {{1997, 01, 02}, {12, 35, 42}},
    Info = #file_info{mode=8#400, atime=Time, mtime=Time, ctime=Time},
    ok = ?PRIM_FILE:write_file_info(Name, Info),

    %% Read back the times.

    {ok, ActualInfo} =
	?PRIM_FILE:read_file_info(Name),
    #file_info{mode=_Mode, atime=ActAtime, mtime=Time,
	       ctime=ActCtime} = ActualInfo,
    FilteredAtime = filter_atime(Time, Config),
    FilteredAtime = filter_atime(ActAtime, Config),
    case os:type() of
	{win32, _} ->
	    %% On Windows, "ctime" means creation time and it can
	    %% be set.
	    ActCtime = Time;
	_ ->
	    ok
    end,
    {error, eacces} = ?PRIM_FILE:write_file(Name, "hello again"),

    %% Make the file writable again.
    ?PRIM_FILE:write_file_info(Name, #file_info{mode=8#600}),
    ok = ?PRIM_FILE:write_file(Name, "hello again"),

    %% And unwritable.
    ?PRIM_FILE:write_file_info(Name, #file_info{mode=8#400}),
    {error, eacces} = ?PRIM_FILE:write_file(Name, "hello again"),

    %% Write the times again.
    %% Note: Seconds must be even; see note in file_info_times/1.

    NewTime = {{1997, 02, 15}, {13, 18, 20}},
    NewInfo = #file_info{atime=NewTime, mtime=NewTime, ctime=NewTime},
    ok = ?PRIM_FILE:write_file_info(Name, NewInfo),
    {ok, ActualInfo2} =
	?PRIM_FILE:read_file_info(Name),
    #file_info{atime=NewActAtime, mtime=NewTime,
	       ctime=NewActCtime} = ActualInfo2,
    NewFilteredAtime = filter_atime(NewTime, Config),
    NewFilteredAtime = filter_atime(NewActAtime, Config),
    case os:type() of
	{win32, _} -> NewActCtime = NewTime;
	_ -> ok
    end,

    %% The file should still be unwritable.
    {error, eacces} = ?PRIM_FILE:write_file(Name, "hello again"),

    %% Make the file writeable again, so that we can remove the
    %% test suites ... :-)
    ?PRIM_FILE:write_file_info(Name, #file_info{mode=8#600}),
    ok.

%% Test the write_file_info/3 function.

file_write_file_info_opts(Config) when is_list(Config) ->
    RootDir = get_good_directory(Config),
    io:format("RootDir = ~p", [RootDir]),

    Name = filename:join(RootDir, atom_to_list(?MODULE) ++"_write_file_info_opts"),
    ok   = ?PRIM_FILE:write_file(Name, "hello_opts"),

    lists:foreach(fun
		      ({FI, Opts}) ->
			 ok = ?PRIM_FILE:write_file_info(Name, FI, Opts)
		 end, [
			{#file_info{ mode=8#600, atime = Time, mtime = Time, ctime = Time}, Opts} ||
			  Opts <- [[{time, posix}]],
			  Time <- [ 0,1,-1,100,-100,1000,-1000,10000,-10000 ]
		      ]),

    %% REM: determine date range dependent on time_t = Uint32 | Sint32 | Sint64 | Uint64
    %% Determine time_t on os:type()?
    lists:foreach(fun ({FI, Opts}) ->
			 ok = ?PRIM_FILE:write_file_info(Name, FI, Opts)
		 end, [ {#file_info{ mode=8#400, atime = Time, mtime = Time, ctime = Time}, Opts} ||
			  Opts <- [[{time, universal}],[{time, local}]],
			  Time <- [
				   {{1970,1,1},{0,0,0}},
				   {{1970,1,1},{0,0,1}},
			%	   {{1969,12,31},{23,59,59}},
			%	   {{1908,2,3},{23,59,59}},
				   {{2012,2,3},{23,59,59}},
				   {{2037,2,3},{23,59,59}},
				   erlang:localtime()
				  ]]),
    ok.

file_read_file_info_opts(Config) when is_list(Config) ->
    RootDir = get_good_directory(Config),
    io:format("RootDir = ~p", [RootDir]),

    Name = filename:join(RootDir, atom_to_list(?MODULE) ++"_read_file_info_opts"),
    ok   = ?PRIM_FILE:write_file(Name, "hello_opts"),

    lists:foreach(fun
		      (Opts) ->
			 {ok,_} = ?PRIM_FILE:read_file_info(Name, Opts)
		 end, [[{time, Type}] || Type <- [local, universal, posix]]),
    ok.

%% Test the write and read back *_file_info/3 functions.

file_write_read_file_info_opts(Config) when is_list(Config) ->
    RootDir = get_good_directory(Config),
    io:format("RootDir = ~p", [RootDir]),

    Name = filename:join(RootDir, atom_to_list(?MODULE) ++"_read_write_file_info_opts"),
    ok   = ?PRIM_FILE:write_file(Name, "hello_opts2"),

    ok = file_write_read_file_info_opts(Name, {{1989, 04, 28}, {19,30,22}}, [{time, local}]),
    ok = file_write_read_file_info_opts(Name, {{1989, 04, 28}, {19,30,22}}, [{time, universal}]),
    %% will not work on platforms with unsigned time_t
    %ok = file_write_read_file_info_opts(Name, {{1930, 04, 28}, {19,30,22}}, [{time, local}]),
    %ok = file_write_read_file_info_opts(Name, {{1930, 04, 28}, {19,30,22}}, [{time, universal}]),
    ok = file_write_read_file_info_opts(Name, 1, [{time, posix}]),
    %% will not work on platforms with unsigned time_t
    %ok = file_write_read_file_info_opts(Name, -1, [{time, posix}]),
    %ok = file_write_read_file_info_opts(Name, -300000, [{time, posix}]),
    ok = file_write_read_file_info_opts(Name, 300000, [{time, posix}]),
    ok = file_write_read_file_info_opts(Name, 0, [{time, posix}]),

    ok.

file_write_read_file_info_opts(Name, Mtime, Opts) ->
    {ok, FI} = ?PRIM_FILE:read_file_info(Name, Opts),
    FI2 = FI#file_info{ mtime = Mtime },
    ok = ?PRIM_FILE:write_file_info(Name, FI2, Opts),
    {ok, FI3} = ?PRIM_FILE:read_file_info(Name, Opts),
    io:format("Expecting mtime = ~p, got ~p~n", [FI2#file_info.mtime, FI3#file_info.mtime]),
    FI2 = FI3,
    ok.



%% Returns a directory on a file system that has correct file times.

get_good_directory(Config) ->
    proplists:get_value(priv_dir, Config).

truncate(Config) when is_list(Config) ->
    RootDir = proplists:get_value(priv_dir,Config),
    Name = filename:join(RootDir,
			 atom_to_list(?MODULE)
			 ++"_truncate.fil"),

    %% Create a file with some data.
    MyData = "0123456789abcdefghijklmnopqrstuvxyz",
    ok = ?PRIM_FILE:write_file(Name, MyData),

    %% Truncate the file to 10 characters.
    {ok, Fd} = ?PRIM_FILE:open(Name, [read, write]),
    {ok, 10} = ?PRIM_FILE:position(Fd, 10),
    ok = ?PRIM_FILE:truncate(Fd),
    ok = ?PRIM_FILE:close(Fd),

    %% Read back the file and check that it has been truncated.
    Expected = list_to_binary("0123456789"),
    {ok, Expected} = ?PRIM_FILE:read_file(Name),

    %% Open the file read only and verify that it is not possible to
    %% truncate it, OTP-1960
    {ok, Fd2} = ?PRIM_FILE:open(Name, [read]),
    {ok, 5} = ?PRIM_FILE:position(Fd2, 5),
    {error, _} = ?PRIM_FILE:truncate(Fd2),

    ok.


%% Tests that ?PRIM_FILE:datasync/1 at least doesn't crash.
datasync(Config) when is_list(Config) ->
    PrivDir = proplists:get_value(priv_dir, Config),
    Sync = filename:join(PrivDir,
			 atom_to_list(?MODULE)
			 ++"_sync.fil"),

    %% Raw open.
    {ok, Fd} = ?PRIM_FILE:open(Sync, [write]),
    ok = ?PRIM_FILE:datasync(Fd),
    ok = ?PRIM_FILE:close(Fd),

    ok.


%% Tests that ?PRIM_FILE:sync/1 at least doesn't crash.
sync(Config) when is_list(Config) ->
    PrivDir = proplists:get_value(priv_dir, Config),
    Sync = filename:join(PrivDir,
			 atom_to_list(?MODULE)
			 ++"_sync.fil"),

    %% Raw open.
    {ok, Fd} = ?PRIM_FILE:open(Sync, [write]),
    ok = ?PRIM_FILE:sync(Fd),
    ok = ?PRIM_FILE:close(Fd),

    ok.


%% Tests that ?PRIM_FILE:advise/4 at least doesn't crash.
advise(Config) when is_list(Config) ->
    PrivDir = proplists:get_value(priv_dir, Config),
    Advise = filename:join(PrivDir,
			   atom_to_list(?MODULE)
			   ++"_advise.fil"),

    Line1 = <<"Hello\n">>,
    Line2 = <<"World!\n">>,

    {ok, Fd} = ?PRIM_FILE:open(Advise, [write]),
    ok = ?PRIM_FILE:advise(Fd, 0, 0, normal),
    ok = ?PRIM_FILE:write(Fd, Line1),
    ok = ?PRIM_FILE:write(Fd, Line2),
    ok = ?PRIM_FILE:close(Fd),

    {ok, Fd2} = ?PRIM_FILE:open(Advise, [write]),
    ok = ?PRIM_FILE:advise(Fd2, 0, 0, random),
    ok = ?PRIM_FILE:write(Fd2, Line1),
    ok = ?PRIM_FILE:write(Fd2, Line2),
    ok = ?PRIM_FILE:close(Fd2),

    {ok, Fd3} = ?PRIM_FILE:open(Advise, [write]),
    ok = ?PRIM_FILE:advise(Fd3, 0, 0, sequential),
    ok = ?PRIM_FILE:write(Fd3, Line1),
    ok = ?PRIM_FILE:write(Fd3, Line2),
    ok = ?PRIM_FILE:close(Fd3),

    {ok, Fd4} = ?PRIM_FILE:open(Advise, [write]),
    ok = ?PRIM_FILE:advise(Fd4, 0, 0, will_need),
    ok = ?PRIM_FILE:write(Fd4, Line1),
    ok = ?PRIM_FILE:write(Fd4, Line2),
    ok = ?PRIM_FILE:close(Fd4),

    {ok, Fd5} = ?PRIM_FILE:open(Advise, [write]),
    ok = ?PRIM_FILE:advise(Fd5, 0, 0, dont_need),
    ok = ?PRIM_FILE:write(Fd5, Line1),
    ok = ?PRIM_FILE:write(Fd5, Line2),
    ok = ?PRIM_FILE:close(Fd5),

    {ok, Fd6} = ?PRIM_FILE:open(Advise, [write]),
    ok = ?PRIM_FILE:advise(Fd6, 0, 0, no_reuse),
    ok = ?PRIM_FILE:write(Fd6, Line1),
    ok = ?PRIM_FILE:write(Fd6, Line2),
    ok = ?PRIM_FILE:close(Fd6),

    {ok, Fd7} = ?PRIM_FILE:open(Advise, [write]),
    {error, einval} = ?PRIM_FILE:advise(Fd7, 0, 0, bad_advise),
    ok = ?PRIM_FILE:close(Fd7),

    %% test write without advise, then a read after an advise
    {ok, Fd8} = ?PRIM_FILE:open(Advise, [write]),
    ok = ?PRIM_FILE:write(Fd8, Line1),
    ok = ?PRIM_FILE:write(Fd8, Line2),
    ok = ?PRIM_FILE:close(Fd8),
    {ok, Fd9} = ?PRIM_FILE:open(Advise, [read]),
    Offset = 0,
    %% same as a 0 length in some implementations
    Length = byte_size(Line1) + byte_size(Line2),
    ok = ?PRIM_FILE:advise(Fd9, Offset, Length, sequential),
    {ok, Line1} = ?PRIM_FILE:read_line(Fd9),
    {ok, Line2} = ?PRIM_FILE:read_line(Fd9),
    eof = ?PRIM_FILE:read_line(Fd9),
    ok = ?PRIM_FILE:close(Fd9),

    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

large_write(Config) when is_list(Config) ->
    run_large_file_test(Config,
			fun(Name) -> do_large_write(Name) end,
			"_large_write").

do_large_write(Name) ->
    ChunkSize = (256 bsl 20) + 1,	% 256 M + 1
    Chunks = 16,			% times 16 -> 4 G + 16
    Base = 100,
    Interleave = lists:seq(Base+1, Base+Chunks),
    Chunk = <<0:ChunkSize/unit:8>>,
    Data = zip_data(lists:duplicate(Chunks, Chunk), Interleave),
    Size = Chunks * ChunkSize + Chunks,	% 4 G + 32
    ok = ?PRIM_FILE:write_file(Name, Data),
    {ok,#file_info{size=Size}} = file:read_file_info(Name),
    {ok,Fd} = ?PRIM_FILE:open(Name, [read]),
    check_large_write(Fd, ChunkSize, 0, Interleave).

check_large_write(Fd, ChunkSize, Pos, [X|Interleave]) ->
    Pos1 = Pos + ChunkSize,
    {ok,Pos1} = ?PRIM_FILE:position(Fd, {cur,ChunkSize}),
    {ok,<<X>>} = ?PRIM_FILE:read(Fd, 1),
    check_large_write(Fd, ChunkSize, Pos1+1, Interleave);
check_large_write(Fd, _, _, []) ->
    eof = ?PRIM_FILE:read(Fd, 1),
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Tests that ?PRIM_FILE:allocate/3 at least doesn't crash.
allocate(Config) when is_list(Config) ->
    PrivDir = proplists:get_value(priv_dir, Config),
    Allocate = filename:join(PrivDir,
			     atom_to_list(?MODULE)
			     ++"_allocate.fil"),

    Line1 = "Hello\n",
    Line2 = "World!\n",

    {ok, Fd} = ?PRIM_FILE:open(Allocate, [write, binary]),
    allocate_and_assert(Fd, 1, iolist_size([Line1, Line2])),
    ok = ?PRIM_FILE:write(Fd, Line1),
    ok = ?PRIM_FILE:write(Fd, Line2),
    ok = ?PRIM_FILE:close(Fd),

    {ok, Fd2} = ?PRIM_FILE:open(Allocate, [write, binary]),
    allocate_and_assert(Fd2, 1, iolist_size(Line1)),
    ok = ?PRIM_FILE:write(Fd2, Line1),
    ok = ?PRIM_FILE:write(Fd2, Line2),
    ok = ?PRIM_FILE:close(Fd2),

    {ok, Fd3} = ?PRIM_FILE:open(Allocate, [write, binary]),
    allocate_and_assert(Fd3, 1, iolist_size(Line1) + 1),
    ok = ?PRIM_FILE:write(Fd3, Line1),
    ok = ?PRIM_FILE:write(Fd3, Line2),
    ok = ?PRIM_FILE:close(Fd3),

    {ok, Fd4} = ?PRIM_FILE:open(Allocate, [write, binary]),
    allocate_and_assert(Fd4, 1, 4 * iolist_size([Line1, Line2])),
    ok = ?PRIM_FILE:write(Fd4, Line1),
    ok = ?PRIM_FILE:write(Fd4, Line2),
    ok = ?PRIM_FILE:close(Fd4),

    ok.

allocate_and_assert(Fd, Offset, Length) ->
    %% Just verify that calls to ?PRIM_FILE:allocate/3 don't crash or have
    %% any other negative side effect. We can't really assert against a
    %% specific return value, because support for file space pre-allocation
    %% depends on the OS, OS version and underlying filesystem.
    %%
    %% The Linux kernel added support for fallocate() in version 2.6.23,
    %% which currently works only for the ext4, ocfs2, xfs and btrfs file
    %% systems. posix_fallocate() is available in glibc as of version
    %% 2.1.94, but it was buggy until glibc version 2.7.
    %%
    %% Mac OS X, as of version 10.3, supports the fcntl operation F_PREALLOCATE.
    %%
    %% Solaris supports posix_fallocate() but only for the UFS file system
    %% apparently (not supported for ZFS).
    %%
    %% FreeBSD 9.0 is the first FreeBSD release supporting posix_fallocate().
    %%
    %% For Windows there's apparently no way to pre-allocate file space, at
    %% least with similar API/semantics as posix_fallocate(), fallocate() or
    %% fcntl F_PREALLOCATE.
    Result = ?PRIM_FILE:allocate(Fd, Offset, Length),
    case os:type() of
        {win32, _} ->
            {error, enotsup} = Result;
        _ ->
            _ = Result
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

delete(Config) when is_list(Config) ->
    RootDir = proplists:get_value(priv_dir,Config),
    Name = filename:join(RootDir,
			 atom_to_list(?MODULE)
			 ++"_delete.fil"),
    {ok, Fd1} = ?PRIM_FILE:open(Name, [write]),
    ?PRIM_FILE:write(Fd1,"ok.\n"),
    ok = ?PRIM_FILE:close(Fd1),
    %% Check that the file is readable
    {ok, Fd2} = ?PRIM_FILE:open(Name, [read]),
    ok = ?PRIM_FILE:close(Fd2),
    ok = ?PRIM_FILE:delete(Name),
    %% Check that the file is not readable anymore
    {error, _} = ?PRIM_FILE:open(Name, [read]),
    %% Try deleting a nonexistent file
    {error, enoent} = ?PRIM_FILE:delete(Name),
    ok.

rename(Config) when is_list(Config) ->
    RootDir = proplists:get_value(priv_dir,Config),
    FileName1 = atom_to_list(?MODULE)++"_rename.fil",
    FileName2 = atom_to_list(?MODULE)++"_rename.ful",
    Name1 = filename:join(RootDir, FileName1),
    Name2 = filename:join(RootDir, FileName2),
    {ok,Fd1} = ?PRIM_FILE:open(Name1, [write]),
    ok = ?PRIM_FILE:close(Fd1),
    %% Rename, and check that it really changed name
    ok = ?PRIM_FILE:rename(Name1, Name2),
    {error, _} = ?PRIM_FILE:open(Name1, [read]),
    {ok, Fd2} = ?PRIM_FILE:open(Name2, [read]),
    ok = ?PRIM_FILE:close(Fd2),
    %% Try renaming something to itself
    ok = ?PRIM_FILE:rename(Name2, Name2),
    %% Try renaming something that doesn't exist
    {error, enoent} =
	?PRIM_FILE:rename(Name1, Name2),
    %% Try renaming to something else than a string
    {error, badarg} =
	?PRIM_FILE:rename(Name1, foobar),

    %% Move between directories
    DirName1 = filename:join(RootDir,
			     atom_to_list(?MODULE)
			     ++"_rename_dir"),
    DirName2 = filename:join(RootDir,
			     atom_to_list(?MODULE)
			     ++"_second_rename_dir"),
    Name1foo = filename:join(DirName1, "foo.fil"),
    Name2foo = filename:join(DirName2, "foo.fil"),
    Name2bar = filename:join(DirName2, "bar.dir"),
    ok = ?PRIM_FILE:make_dir(DirName1),
    %% The name has to include the full file name, path is not enough
    expect(
      {error, eexist}, {error, eisdir},
      ?PRIM_FILE:rename(Name2, DirName1)),
    ok =
	?PRIM_FILE:rename(Name2, Name1foo),
    %% Now rename the directory
    ok = ?PRIM_FILE:rename(DirName1, DirName2),
    %% And check that the file is there now
    {ok,Fd3} = ?PRIM_FILE:open(Name2foo, [read]),
    ok = ?PRIM_FILE:close(Fd3),
    %% Try some dirty things now: move the directory into itself
    {error, Msg1} =
	?PRIM_FILE:rename(DirName2, Name2bar),
    io:format("Errmsg1: ~p",[Msg1]),
    %% move dir into a file in itself
    {error, Msg2} =
	?PRIM_FILE:rename(DirName2, Name2foo),
    io:format("Errmsg2: ~p",[Msg2]),

    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


e_delete(Config) when is_list(Config) ->
    RootDir = proplists:get_value(priv_dir, Config),
    Base = filename:join(RootDir,
			 atom_to_list(?MODULE)++"_e_delete"),
    ok = ?PRIM_FILE:make_dir(Base),

    %% Delete a non-existing file.
    {error, enoent} =
	?PRIM_FILE:delete(filename:join(Base, "non_existing")),

    %% Delete a directory.
    {error, eperm} = ?PRIM_FILE:delete(Base),

    %% Use a path-name with a non-directory component.
    Afile = filename:join(Base, "a_file"),
    ok = ?PRIM_FILE:write_file(Afile, "hello\n"),
    {error, E} =
	expect(
	  {error, enotdir}, {error, enoent}, 
	  ?PRIM_FILE:delete(filename:join(Afile, "another_file"))),
    io:format("Result: ~p~n", [E]),

    %% No permission.
    case os:type() of
	{win32, _} ->
	    %% Remove a character device.
	    expect({error, eacces}, {error, einval},
                   ?PRIM_FILE:delete("nul"));
	_ ->
	    ?PRIM_FILE:write_file_info(
	       Base, #file_info {mode=0}),
	    {error, eacces} = ?PRIM_FILE:delete(Afile),
	    ?PRIM_FILE:write_file_info(
	       Base, #file_info {mode=8#700})
    end,

    ok.

%%% FreeBSD gives EEXIST when renaming a file to an empty dir, although the
%%% manual page can be interpreted as saying that EISDIR should be given.
%%% (What about FreeBSD? We store our nightly build results on a FreeBSD
%%% file system, that's what.)

e_rename(Config) when is_list(Config) ->
    RootDir = proplists:get_value(priv_dir, Config),
    Base = filename:join(RootDir,
			 atom_to_list(?MODULE)++"_e_rename"),
    ok = ?PRIM_FILE:make_dir(Base),

    %% Create an empty directory.
    EmptyDir = filename:join(Base, "empty_dir"),
    ok = ?PRIM_FILE:make_dir(EmptyDir),

    %% Create a non-empty directory.
    NonEmptyDir = filename:join(Base, "non_empty_dir"),
    ok = ?PRIM_FILE:make_dir(NonEmptyDir),
    ok = ?PRIM_FILE:write_file(
	    filename:join(NonEmptyDir, "a_file"),
	    "hello\n"),

    %% Create another non-empty directory.
    ADirectory = filename:join(Base, "a_directory"),
    ok = ?PRIM_FILE:make_dir(ADirectory),
    ok = ?PRIM_FILE:write_file(
	    filename:join(ADirectory, "a_file"),
	    "howdy\n\n"),

    %% Create a data file.
    File = filename:join(Base, "just_a_file"),
    ok = ?PRIM_FILE:write_file(File, "anything goes\n\n"),

    %% Move an existing directory to a non-empty directory.
    {error, eexist} =
	?PRIM_FILE:rename(ADirectory, NonEmptyDir),

    %% Move a root directory.
    {error, einval} = ?PRIM_FILE:rename("/", "arne"),

    %% Move Base into Base/new_name.
    {error, einval} =
	?PRIM_FILE:rename(Base, filename:join(Base, "new_name")),

    %% Overwrite a directory with a file.
    expect({error, eexist}, % FreeBSD (?)
	   {error, eisdir},
	   ?PRIM_FILE:rename(File, EmptyDir)),
    expect({error, eexist}, % FreeBSD (?)
	   {error, eisdir},
	   ?PRIM_FILE:rename(File, NonEmptyDir)),

    %% Move a non-existing file.
    NonExistingFile = filename:join(
			Base, "non_existing_file"),
    {error, enoent} =
	?PRIM_FILE:rename(NonExistingFile, NonEmptyDir),

    %% Overwrite a file with a directory.
    expect({error, eexist}, % FreeBSD (?)
	   {error, enotdir},
	   ?PRIM_FILE:rename(ADirectory, File)),

    %% Move a file to another filesystem.
    %% XXX - This test case is bogus. We cannot be guaranteed that
    %%       the source and destination are on 
    %%       different filesystems.
    %%
    %% XXX - Gross hack!
    Comment =
	case os:type() of
	    {win32, _} ->
		%% At least Windows NT can
		%% successfully move a file to
		%% another drive.
		ok;
	    _ ->
		OtherFs = "/tmp",
		NameOnOtherFs =
		    filename:join(OtherFs,
				  filename:basename(File)),
		{ok, Com} =
		    case ?PRIM_FILE:rename(
			    File, NameOnOtherFs) of
			{error, exdev} ->
			    %% The file could be in
			    %% the same filesystem!
			    {ok, ok};
			ok ->
			    {ok, {comment,
				  "Moving between filesystems "
				  "succeeded, files are probably "
				  "in the same filesystem!"}};
			{error, eperm} ->
			    {ok, {comment, "SBS! You don't "
				  "have the permission to do "
				  "this test!"}};
			Else ->
			    Else
		    end,
		Com
	end,
    Comment.

e_make_dir(Config) when is_list(Config) ->
    RootDir = proplists:get_value(priv_dir, Config),
    Base = filename:join(RootDir,
			 atom_to_list(?MODULE)++"_e_make_dir"),
    ok = ?PRIM_FILE:make_dir(Base),

    %% A component of the path does not exist.
    {error, enoent} =
	?PRIM_FILE:make_dir(filename:join([Base, "a", "b"])),

    %% Use a path-name with a non-directory component.
    Afile = filename:join(Base, "a_directory"),
    ok = ?PRIM_FILE:write_file(Afile, "hello\n"),
    case ?PRIM_FILE:make_dir(
	    filename:join(Afile, "another_directory")) of
	{error, enotdir} -> io:format("Result: enotdir");
	{error, enoent} -> io:format("Result: enoent")
    end,

    %% No permission (on Unix only).
    case os:type() of
	{win32, _} ->
	    ok;
	_ ->
	    ?PRIM_FILE:write_file_info(Base, #file_info {mode=0}),
	    {error, eacces} =
		?PRIM_FILE:make_dir(filename:join(Base, "xxxx")),
	    ?PRIM_FILE:write_file_info(Base, #file_info {mode=8#700})
    end,
    ok.

e_del_dir(Config) when is_list(Config) ->
    RootDir = proplists:get_value(priv_dir, Config),
    Base = filename:join(RootDir,
			 atom_to_list(?MODULE)++"_e_del_dir"),
    io:format("Base: ~p", [Base]),
    ok = ?PRIM_FILE:make_dir(Base),

    %% Delete a non-existent directory.
    {error, enoent} =
	?PRIM_FILE:del_dir(filename:join(Base, "non_existing")),

    %% Use a path-name with a non-directory component.
    Afile = filename:join(Base, "a_directory"),
    ok = ?PRIM_FILE:write_file(Afile, "hello\n"),
    {error, E1} =
	expect({error, enotdir}, {error, enoent},
	       ?PRIM_FILE:del_dir(
		  filename:join(Afile, "another_directory"))),
    io:format("Result: ~p", [E1]),

    %% Delete a non-empty directory.
    %% Delete a non-empty directory.
    {error, E2} =
	expect({error, enotempty}, {error, eexist}, {error, eacces},
	       ?PRIM_FILE:del_dir(Base)),
    io:format("Result: ~p", [E2]),

    %% Remove the current directory.
    {error, E3} =
	expect({error, einval}, 
	       {error, eperm}, % Linux and DUX
	       {error, eacces},
	       {error, ebusy},
	       ?PRIM_FILE:del_dir(".")),
    io:format("Result: ~p", [E3]),

    %% No permission.
    case os:type() of
	{win32, _} ->
	    ok;
	_ ->
	    ADirectory = filename:join(Base, "no_perm"),
	    ok = ?PRIM_FILE:make_dir(ADirectory),
	    ?PRIM_FILE:write_file_info(Base, #file_info {mode=0}),
	    {error, eacces} = ?PRIM_FILE:del_dir(ADirectory),
	    ?PRIM_FILE:write_file_info(
	       Base, #file_info {mode=8#700})
    end,
    ok.


make_link(Config) when is_list(Config) ->
    RootDir = proplists:get_value(priv_dir, Config),
    NewDir = filename:join(RootDir,
			   atom_to_list(?MODULE)
			   ++"_make_link"),
    ok = ?PRIM_FILE:make_dir(NewDir),

    Name = filename:join(NewDir, "a_file"),
    ok = ?PRIM_FILE:write_file(Name, "some contents\n"),

    Alias = filename:join(NewDir, "an_alias"),
    Result =
	case ?PRIM_FILE:make_link(Name, Alias) of
	    {error, enotsup} ->
		{skipped, "Links not supported on this platform"};
	    ok ->
		%% Note: We take the opportunity to test 
		%% ?PRIM_FILE:read_link_info/1,
		%% which should in behave exactly as 
		%% ?PRIM_FILE:read_file_info/1
		%% since they are not used on symbolic links.

		{ok, Info} =
		    ?PRIM_FILE:read_link_info(Name),
		{ok, Info} =
		    ?PRIM_FILE:read_link_info(Alias),
		#file_info{links = 2, type = regular} = Info,
		{error, eexist} =
		    ?PRIM_FILE:make_link(Name, Alias),
		ok
	end,

    Result.

%% Test that reading link info for an ordinary file or directory works
%% (on all platforms).
read_link_info_for_non_link(Config) when is_list(Config) ->
    {ok, #file_info{type=directory}} = ?PRIM_FILE:read_link_info("."),
    ok.

symlinks(Config) when is_list(Config)  ->
    RootDir = proplists:get_value(priv_dir, Config),
    NewDir = filename:join(RootDir,
			   atom_to_list(?MODULE)
			   ++"_make_symlink"),
    ok = ?PRIM_FILE:make_dir(NewDir),

    Name = filename:join(NewDir, "a_plain_file"),
    ok = ?PRIM_FILE:write_file(Name, "some stupid content\n"),

    Alias = filename:join(NewDir, "a_symlink_alias"),
    Result =
	case ?PRIM_FILE:make_symlink(Name, Alias) of
	    {error, enotsup} ->
		{skipped, "Links not supported on this platform"};
	    {error, eperm} ->
		{win32,_} = os:type(),
		{skipped, "Windows user not privileged to create links"};
	    ok ->
		{ok, Info1} =
		    ?PRIM_FILE:read_file_info(Name),
		{ok, Info1} =
		    ?PRIM_FILE:read_file_info(Alias),
		{ok, Info1} =
		    ?PRIM_FILE:read_link_info(Name),
		#file_info{links = 1, type = regular} = Info1,

		{ok, Info2} =
		    ?PRIM_FILE:read_link_info(Alias),
		#file_info{links=1, type=symlink} = Info2,
		{ok, Name} =
		    ?PRIM_FILE:read_link(Alias),
		{ok, Name} =
		    ?PRIM_FILE:read_link_all(Alias),
		%% If all is good, delete dir again (avoid hanging dir on windows)
		rm_rf(?PRIM_FILE,NewDir),
		ok
	end,

    Result.

%% Creates as many files as possible during a certain time, 
%% periodically calls list_dir/2 to check if it works,
%% then deletes all files.

%% Tests if large directories can be read.
list_dir_limit(Config) when is_list(Config) ->
    MaxTime = 120,
    MaxNumber = 20000,
    ct:timetrap({seconds,2*MaxTime + MaxTime}),
    RootDir = proplists:get_value(priv_dir, Config),
    NewDir = filename:join(RootDir,
			   atom_to_list(?MODULE)++"_list_dir_limit"),
    ok = ?PRIM_FILE:make_dir(NewDir),
    Ref = erlang:start_timer(MaxTime*1000, self(), []),
    Result = list_dir_limit_loop(NewDir, Ref, MaxNumber, 0),
    Time = case erlang:cancel_timer(Ref) of
	       false -> MaxTime;
	       T -> MaxTime - (T div 1000)
	   end,
    Number = case Result of
		 {ok, N} -> N;
		 {error, _Reason, N} -> N;
		 _ -> 0
	     end,
    list_dir_limit_cleanup(NewDir, Number, 0),
    {ok, Number} = Result,
    {comment, 
     "Created " ++ integer_to_list(Number) ++ " files in " 
     ++ integer_to_list(Time) ++ " seconds."}.

list_dir_limit_loop(Dir, _Ref, N, Cnt) when Cnt >= N ->
    list_dir_check(Dir, Cnt);
list_dir_limit_loop(Dir, Ref, N, Cnt) ->
    receive 
	{timeout, Ref, []} -> 
	    list_dir_check(Dir, Cnt)
    after 0 ->
	    Name = integer_to_list(Cnt),
	    case ?PRIM_FILE:write_file(filename:join(Dir, Name), Name) of
		ok ->
		    Next = Cnt + 1,
		    case Cnt rem 100 of
			0 ->
			    case list_dir_check(Dir, Next) of
				{ok, Next} ->
				    list_dir_limit_loop(
				      Dir, Ref, N, Next);
				Other ->
				    Other
			    end;
			_ ->
			    list_dir_limit_loop(Dir, Ref, N, Next)
		    end;
		{error, Reason} ->
		    {error, Reason, Cnt}
	    end
    end.

list_dir_check(Dir, Cnt) ->
    case ?PRIM_FILE:list_dir(Dir) of
	{ok, ListDir} ->
	    case length(ListDir) of
		Cnt ->
		    {ok, Cnt};
		X ->
		    {error, 
		     {wrong_nof_files, X, ?LINE},
		     Cnt}
	    end;
	{error, Reason} ->
	    {error, Reason, Cnt}
    end.

%% Deletes N files while ignoring errors, then continues deleting
%% as long as they exist.

list_dir_limit_cleanup(Dir, N, Cnt) when Cnt >= N ->
    Name = integer_to_list(Cnt),
    case ?PRIM_FILE:delete(filename:join(Dir, Name)) of
	ok ->
	    list_dir_limit_cleanup(Dir, N, Cnt+1);
	_ ->
	    ok
    end;
list_dir_limit_cleanup(Dir, N, Cnt) ->
    Name = integer_to_list(Cnt),
    ?PRIM_FILE:delete(filename:join(Dir, Name)),
    list_dir_limit_cleanup(Dir, N, Cnt+1).

%%%
%%% Test list_dir() on a non-existing pathname.
%%%

list_dir_error(Config) ->
    Priv = proplists:get_value(priv_dir, Config),
    NonExisting = filename:join(Priv, "non-existing-dir"),
    {error,enoent} = ?PRIM_FILE:list_dir(NonExisting),
    ok.

%%%
%%% Test list_dir() and list_dir_all().
%%%

list_dir(Config) ->
    RootDir = proplists:get_value(priv_dir, Config),
    TestDir = filename:join(RootDir, ?MODULE_STRING++"_list_dir"),
    ?PRIM_FILE:make_dir(TestDir),
    list_dir_1(TestDir, 42, []).

list_dir_1(TestDir, 0, Sorted) ->
    [ok = ?PRIM_FILE:delete(filename:join(TestDir, F)) ||
	F <- Sorted],
    ok = ?PRIM_FILE:del_dir(TestDir);
list_dir_1(TestDir, Cnt, Sorted0) ->
    Base = "file" ++ integer_to_list(Cnt),
    Name = filename:join(TestDir, Base),
    ok = ?PRIM_FILE:write_file(Name, Base),
    Sorted = lists:merge([Base], Sorted0),
    {ok,DirList0} = ?PRIM_FILE:list_dir(TestDir),
    {ok,DirList1} = ?PRIM_FILE:list_dir_all(TestDir),
    Sorted = lists:sort(DirList0),
    Sorted = lists:sort(DirList1),
    list_dir_1(TestDir, Cnt-1, Sorted).

%% Tests that an open directory can be listed without resolving its path
%% again, so changes to the path do not change the listing.
list_dir_handle(Config) ->
    RootDir = proplists:get_value(priv_dir, Config),
    TestDir = filename:join(RootDir, ?MODULE_STRING++"_list_dir_handle"),
    ok = ?PRIM_FILE:make_dir(TestDir),

    Names = ["file1", "file2", "file3"],
    [ok = ?PRIM_FILE:write_file(filename:join(TestDir, N), N) || N <- Names],
    Sorted = lists:sort(Names),

    {ok, Fd} = ?PRIM_FILE:open(TestDir, [read, directory]),

    %% Both functions list the same contents as the path-based functions.
    {ok, DirList0} = ?PRIM_FILE:list_dir(Fd),
    Sorted = lists:sort(DirList0),
    {ok, DirList1} = ?PRIM_FILE:list_dir_all(Fd),
    Sorted = lists:sort(DirList1),

    %% The caller can list the handle repeatedly.
    {ok, DirList2} = ?PRIM_FILE:list_dir(Fd),
    Sorted = lists:sort(DirList2),

    %% Later listings of the same handle include new entries.
    ok = ?PRIM_FILE:write_file(filename:join(TestDir, "file4"), "file4"),
    AllSorted = lists:sort(["file4" | Names]),
    {ok, DirList3} = ?PRIM_FILE:list_dir(Fd),
    AllSorted = lists:sort(DirList3),

    ok = ?PRIM_FILE:close(Fd),

    %% Listing a handle that is not a directory is an error.
    RegularFile = filename:join(TestDir, "file1"),
    {ok, RegularFd} = ?PRIM_FILE:open(RegularFile, [read]),
    {error, enotdir} = ?PRIM_FILE:list_dir(RegularFd),
    {error, enotdir} = ?PRIM_FILE:list_dir_all(RegularFd),
    ok = ?PRIM_FILE:close(RegularFd),

    %% Listing a closed handle is also an error.
    {ok, ClosedFd} = ?PRIM_FILE:open(TestDir, [read, directory]),
    ok = ?PRIM_FILE:close(ClosedFd),
    {error, einval} = ?PRIM_FILE:list_dir(ClosedFd),

    [ok = ?PRIM_FILE:delete(filename:join(TestDir, N)) || N <- ["file4" | Names]],
    ok = ?PRIM_FILE:del_dir(TestDir),
    ok.

%% Tests that an open file can be changed without resolving its path again,
%% so changes to the path do not change which file is written.
file_write_handle_info(Config) ->
    RootDir = proplists:get_value(priv_dir, Config),
    TestDir = filename:join(RootDir, ?MODULE_STRING++"_write_handle_info"),
    ok = ?PRIM_FILE:make_dir(TestDir),
    Name = filename:join(TestDir, "file"),
    ok = ?PRIM_FILE:write_file(Name, "contents"),

    {ok, Fd} = ?PRIM_FILE:open(Name, [read, write]),
    {ok, Info} = ?PRIM_FILE:read_handle_info(Fd),

    %% Permissions. Windows models only the read-only bit, so the mode it
    %% reports back is not the one that was set. The handle must report what
    %% the path reports, whichever platform this is.
    ok = ?PRIM_FILE:write_file_info(Fd, Info#file_info{mode = 8#600}),
    {ok, Info1} = ?PRIM_FILE:read_handle_info(Fd),
    {ok, Mode1} = ?PRIM_FILE:read_file_info(Name),
    ExpectedMode =
        case os:type() of
            {win32, _} -> Mode1#file_info.mode band 8#777;
            _ -> 8#600
        end,
    ExpectedMode = Info1#file_info.mode band 8#777,

    %% Times. The path variant reports the same values afterwards.
    Time = {{2001, 2, 3}, {4, 5, 6}},
    ok = ?PRIM_FILE:write_file_info(Fd, Info1#file_info{mtime = Time,
                                                       atime = Time}),
    {ok, Info2} = ?PRIM_FILE:read_handle_info(Fd),
    Time = Info2#file_info.mtime,
    {ok, ViaPath} = ?PRIM_FILE:read_file_info(Name),
    Time = ViaPath#file_info.mtime,
    ExpectedMode = ViaPath#file_info.mode band 8#777,

    %% The posix time option works the same way as it does on a path.
    {ok, Info3} = ?PRIM_FILE:read_handle_info(Fd, [{time, posix}]),
    ok = ?PRIM_FILE:write_file_info(Fd, Info3#file_info{mtime = 1000000},
                                    [{time, posix}]),
    {ok, Info4} = ?PRIM_FILE:read_handle_info(Fd, [{time, posix}]),
    1000000 = Info4#file_info.mtime,

    ok = ?PRIM_FILE:close(Fd),

    %% Writing through a closed handle is an error.
    {error, einval} = ?PRIM_FILE:write_file_info(Fd, Info#file_info{mode = 8#644}),

    ok = ?PRIM_FILE:write_file_info(Name, Info#file_info{mode = 8#644}),
    ok = ?PRIM_FILE:delete(Name),
    ok = ?PRIM_FILE:del_dir(TestDir),
    ok.

%% Tests that a raw file can change owner. The emulator closes a file when the
%% process that owns it dies, so the file has to follow its new owner.
adopt(Config) ->
    RootDir = proplists:get_value(priv_dir, Config),
    TestDir = filename:join(RootDir, ?MODULE_STRING++"_adopt"),
    ok = ?PRIM_FILE:make_dir(TestDir),
    Name = filename:join(TestDir, "file"),
    ok = ?PRIM_FILE:write_file(Name, "contents"),
    Parent = self(),

    %% A file that another process opened stays open after that process dies,
    %% because this process adopted it.
    Opener = spawn(fun() ->
                           {ok, Fd} = ?PRIM_FILE:open(Name, [read]),
                           Parent ! {self(), Fd},
                           receive done -> ok end
                   end),
    Fd = receive {Opener, F} -> F end,
    {ok, Adopted} = ?PRIM_FILE:adopt(Fd),
    ok = stop_and_wait(Opener),
    {ok, <<"contents">>} = ?PRIM_FILE:read(Adopted, 100),
    ok = ?PRIM_FILE:close(Adopted),

    %% A file that this process opened is closed when the process that adopted
    %% it dies.
    {ok, Fd2} = ?PRIM_FILE:open(Name, [read]),
    Taker = spawn(fun() ->
                          {ok, _} = ?PRIM_FILE:adopt(Fd2),
                          Parent ! {self(), adopted},
                          receive done -> ok end
                  end),
    receive {Taker, adopted} -> ok end,
    ok = stop_and_wait(Taker),
    ok = wait_until_closed(Fd2),

    %% A closed file cannot be adopted.
    {error, einval} = ?PRIM_FILE:adopt(Fd2),

    ok = ?PRIM_FILE:delete(Name),
    ok = ?PRIM_FILE:del_dir(TestDir),
    ok.

stop_and_wait(Pid) ->
    Ref = monitor(process, Pid),
    Pid ! done,
    receive {'DOWN', Ref, process, Pid, _} -> ok end.

%% The emulator closes a file some time after its owner is reported down.
wait_until_closed(Fd) ->
    wait_until_closed(Fd, 100).

wait_until_closed(Fd, N) ->
    case ?PRIM_FILE:read(Fd, 1) of
        {error, einval} ->
            ok;
        Other when N > 0 ->
            io:format("still open: ~p~n", [Other]),
            timer:sleep(10),
            wait_until_closed(Fd, N - 1);
        Other ->
            ct:fail({still_open, Other})
    end.

%% Tests that a name is opened against an open directory, so the path of the
%% directory is not resolved a second time.
open_at(Config) ->
    RootDir = proplists:get_value(priv_dir, Config),
    TestDir = filename:join(RootDir, ?MODULE_STRING++"_open_at"),
    ok = ?PRIM_FILE:make_dir(TestDir),
    Name = filename:join(TestDir, "file"),
    ok = ?PRIM_FILE:write_file(Name, "contents"),

    {ok, Dir} = ?PRIM_FILE:open(TestDir, [read, directory]),

    {ok, Fd} = ?PRIM_FILE:open({Dir, "file"}, [read]),
    {ok, <<"contents">>} = ?PRIM_FILE:read(Fd, 100),
    ok = ?PRIM_FILE:close(Fd),

    %% The file stays open after the directory is closed.
    {ok, Fd2} = ?PRIM_FILE:open({Dir, "file"}, [read]),
    ok = ?PRIM_FILE:close(Dir),
    {ok, <<"contents">>} = ?PRIM_FILE:read(Fd2, 100),
    ok = ?PRIM_FILE:close(Fd2),

    {ok, Dir2} = ?PRIM_FILE:open(TestDir, [read, directory]),

    %% A name that is not in the directory reports the same error as a path
    %% that does not exist.
    {error, enoent} = ?PRIM_FILE:open({Dir2, "missing"}, [read]),

    %% A file can be created through the directory as well.
    {ok, New} = ?PRIM_FILE:open({Dir2, "new"}, [write]),
    ok = ?PRIM_FILE:write(New, "written"),
    ok = ?PRIM_FILE:close(New),
    {ok, <<"written">>} = ?PRIM_FILE:read_file(filename:join(TestDir, "new")),

    %% The modes a path takes are honoured, sync among them.
    {ok, Synced} = ?PRIM_FILE:open({Dir2, "synced"}, [write, sync]),
    ok = ?PRIM_FILE:write(Synced, "synced"),
    ok = ?PRIM_FILE:close(Synced),
    {ok, <<"synced">>} = ?PRIM_FILE:read_file(filename:join(TestDir, "synced")),

    ok = ?PRIM_FILE:close(Dir2),

    %% A file that is not a directory cannot be used to open a name.
    {ok, Plain} = ?PRIM_FILE:open(Name, [read]),
    {error, enotdir} = ?PRIM_FILE:open({Plain, "file"}, [read]),
    ok = ?PRIM_FILE:close(Plain),

    ok = ?PRIM_FILE:delete(filename:join(TestDir, "new")),
    ok = ?PRIM_FILE:delete(filename:join(TestDir, "synced")),
    ok = ?PRIM_FILE:delete(Name),
    ok = ?PRIM_FILE:del_dir(TestDir),
    ok.

%% Tests that the read operations take a name in an open directory, and report
%% what the matching path reports.
read_at(Config) ->
    RootDir = proplists:get_value(priv_dir, Config),
    TestDir = filename:join(RootDir, ?MODULE_STRING++"_read_at"),
    ok = ?PRIM_FILE:make_dir(TestDir),

    Name = filename:join(TestDir, "file"),
    Sub = filename:join(TestDir, "sub"),
    ok = ?PRIM_FILE:write_file(Name, "contents"),
    ok = ?PRIM_FILE:make_dir(Sub),
    ok = ?PRIM_FILE:write_file(filename:join(Sub, "inner"), "inner"),

    {ok, Dir} = ?PRIM_FILE:open(TestDir, [read, directory]),

    {ok, #file_info{type = regular, size = 8}} =
        ?PRIM_FILE:read_file_info({Dir, "file"}),
    {ok, #file_info{type = directory}} =
        ?PRIM_FILE:read_file_info({Dir, "sub"}),
    {ok, #file_info{type = regular}} =
        ?PRIM_FILE:read_link_info({Dir, "file"}),
    {ok, ["inner"]} = ?PRIM_FILE:list_dir({Dir, "sub"}),
    {ok, ["inner"]} = ?PRIM_FILE:list_dir_all({Dir, "sub"}),
    {ok, <<"contents">>} = ?PRIM_FILE:read_file({Dir, "file"}),

    %% The path and the name report the same values.
    {ok, ViaPath} = ?PRIM_FILE:read_file_info(Name),
    {ok, ViaPath} = ?PRIM_FILE:read_file_info({Dir, "file"}),
    {ok, ViaPathPosix} = ?PRIM_FILE:read_file_info(Name, [{time, posix}]),
    {ok, ViaPathPosix} = ?PRIM_FILE:read_file_info({Dir, "file"},
                                                   [{time, posix}]),

    %% Errors match what the matching path reports.
    {error, enoent} = ?PRIM_FILE:read_file_info({Dir, "missing"}),
    {error, enoent} = ?PRIM_FILE:read_link_info({Dir, "missing"}),
    {error, enoent} = ?PRIM_FILE:read_file({Dir, "missing"}),
    {error, enoent} = ?PRIM_FILE:list_dir({Dir, "missing"}),
    {error, enotdir} = ?PRIM_FILE:list_dir({Dir, "file"}),
    {error, einval} = ?PRIM_FILE:read_link({Dir, "file"}),

    %% A file that is not a directory cannot hold a name.
    {ok, Plain} = ?PRIM_FILE:open(Name, [read]),
    {error, enotdir} = ?PRIM_FILE:read_file_info({Plain, "file"}),
    ok = ?PRIM_FILE:close(Plain),

    read_at_symlink(Dir, TestDir),

    ok = ?PRIM_FILE:close(Dir),

    %% A closed directory cannot hold a name either.
    {error, einval} = ?PRIM_FILE:read_file_info({Dir, "file"}),

    ok = ?PRIM_FILE:delete(filename:join(Sub, "inner")),
    ok = ?PRIM_FILE:del_dir(Sub),
    ok = ?PRIM_FILE:delete(Name),
    ok = ?PRIM_FILE:del_dir(TestDir),
    ok.

read_at_symlink(Dir, TestDir) ->
    Link = filename:join(TestDir, "link"),

    case ?PRIM_FILE:make_symlink(filename:join(TestDir, "file"), Link) of
        {error, enotsup} ->
            ok;
        {error, eperm} ->
            {win32,_} = os:type(),
            ok;
        ok ->
            %% read_file_info follows the link, read_link_info does not.
            {ok, #file_info{type = regular}} =
                ?PRIM_FILE:read_file_info({Dir, "link"}),
            {ok, #file_info{type = symlink}} =
                ?PRIM_FILE:read_link_info({Dir, "link"}),
            {ok, ViaPath} = ?PRIM_FILE:read_link_info(Link),
            {ok, ViaPath} = ?PRIM_FILE:read_link_info({Dir, "link"}),

            %% Windows resolves a link to a full path, so the target is only
            %% checked for pointing at the file that was linked.
            {ok, Target} = ?PRIM_FILE:read_link({Dir, "link"}),
            {ok, Target} = ?PRIM_FILE:read_link(Link),
            {ok, Target} = ?PRIM_FILE:read_link_all({Dir, "link"}),
            "file" = filename:basename(Target),

            ok = ?PRIM_FILE:delete(Link),
            ok
    end.

%% Tests that the operations that change the file system take a name in an
%% open directory, and report what the matching path reports.
write_at(Config) ->
    RootDir = proplists:get_value(priv_dir, Config),
    TestDir = filename:join(RootDir, ?MODULE_STRING++"_write_at"),
    ok = ?PRIM_FILE:make_dir(TestDir),

    {ok, Dir} = ?PRIM_FILE:open(TestDir, [read, directory]),

    %% Making and removing a directory.
    ok = ?PRIM_FILE:make_dir({Dir, "sub"}),
    {ok, #file_info{type = directory}} =
        ?PRIM_FILE:read_file_info(filename:join(TestDir, "sub")),
    {error, eexist} = ?PRIM_FILE:make_dir({Dir, "sub"}),
    ok = ?PRIM_FILE:write_file(filename:join([TestDir, "sub", "f"]), "x"),
    {error, eexist} = ?PRIM_FILE:del_dir({Dir, "sub"}),
    ok = ?PRIM_FILE:delete({Dir, "sub/f"}),
    ok = ?PRIM_FILE:del_dir({Dir, "sub"}),
    {error, enoent} = ?PRIM_FILE:read_file_info(filename:join(TestDir, "sub")),

    %% Renaming inside one directory, and over an existing name.
    ok = ?PRIM_FILE:write_file(filename:join(TestDir, "before"), "moved"),
    ok = ?PRIM_FILE:write_file(filename:join(TestDir, "after"), "old"),
    ok = ?PRIM_FILE:rename({Dir, "before"}, {Dir, "after"}),
    {ok, <<"moved">>} = ?PRIM_FILE:read_file(filename:join(TestDir, "after")),
    {error, enoent} = ?PRIM_FILE:read_file_info({Dir, "before"}),

    %% Changing the permissions and the times of a name. The path and the
    %% name report the same values afterwards.
    {ok, Info} = ?PRIM_FILE:read_file_info({Dir, "after"}),
    ok = ?PRIM_FILE:write_file_info({Dir, "after"}, Info#file_info{mode = 8#600}),
    {ok, Info1} = ?PRIM_FILE:read_file_info(filename:join(TestDir, "after")),
    {ok, Info1} = ?PRIM_FILE:read_file_info({Dir, "after"}),

    Time = {{2001, 2, 3}, {4, 5, 6}},
    ok = ?PRIM_FILE:write_file_info({Dir, "after"},
                                    Info1#file_info{mtime = Time, atime = Time}),
    {ok, #file_info{mtime = Time}} = ?PRIM_FILE:read_file_info({Dir, "after"}),
    {ok, #file_info{mtime = Time}} =
        ?PRIM_FILE:read_file_info(filename:join(TestDir, "after")),

    {ok, InfoPosix} = ?PRIM_FILE:read_file_info({Dir, "after"}, [{time, posix}]),
    ok = ?PRIM_FILE:write_file_info({Dir, "after"},
                                    InfoPosix#file_info{mtime = 1000000},
                                    [{time, posix}]),
    {ok, #file_info{mtime = 1000000}} =
        ?PRIM_FILE:read_file_info({Dir, "after"}, [{time, posix}]),

    ok = ?PRIM_FILE:write_file_info({Dir, "after"}, Info#file_info{mode = 8#644}),

    %% Removing a name.
    ok = ?PRIM_FILE:delete({Dir, "after"}),
    {error, enoent} = ?PRIM_FILE:read_file_info(filename:join(TestDir, "after")),

    %% Errors match what the matching path reports.
    {error, enoent} = ?PRIM_FILE:delete({Dir, "missing"}),
    {error, enoent} = ?PRIM_FILE:del_dir({Dir, "missing"}),
    {error, enoent} = ?PRIM_FILE:rename({Dir, "missing"}, {Dir, "other"}),
    {error, enoent} = ?PRIM_FILE:write_file_info({Dir, "missing"}, Info),

    ok = ?PRIM_FILE:write_file(filename:join(TestDir, "plain"), "x"),
    {error, enotdir} = ?PRIM_FILE:del_dir({Dir, "plain"}),
    ok = ?PRIM_FILE:make_dir({Dir, "adir"}),
    {error, eperm} = ?PRIM_FILE:delete({Dir, "adir"}),
    ok = ?PRIM_FILE:del_dir({Dir, "adir"}),
    ok = ?PRIM_FILE:delete({Dir, "plain"}),

    write_at_across_dirs(Dir, TestDir),
    write_at_mixed(Dir, TestDir),

    ok = ?PRIM_FILE:close(Dir),
    ok = ?PRIM_FILE:del_dir(TestDir),
    ok.

%% The two names of a rename may belong to different open directories.
write_at_across_dirs(Dir, TestDir) ->
    ok = ?PRIM_FILE:make_dir({Dir, "from"}),
    ok = ?PRIM_FILE:make_dir({Dir, "to"}),

    {ok, From} = ?PRIM_FILE:open(filename:join(TestDir, "from"),
                                 [read, directory]),
    {ok, To} = ?PRIM_FILE:open(filename:join(TestDir, "to"),
                               [read, directory]),

    ok = ?PRIM_FILE:write_file(filename:join([TestDir, "from", "f"]), "across"),
    ok = ?PRIM_FILE:rename({From, "f"}, {To, "f"}),

    {ok, <<"across">>} =
        ?PRIM_FILE:read_file(filename:join([TestDir, "to", "f"])),
    {error, enoent} = ?PRIM_FILE:read_file_info({From, "f"}),

    ok = ?PRIM_FILE:delete({To, "f"}),
    ok = ?PRIM_FILE:close(From),
    ok = ?PRIM_FILE:close(To),

    ok = ?PRIM_FILE:del_dir({Dir, "from"}),
    ok = ?PRIM_FILE:del_dir({Dir, "to"}),
    ok.

%% One of the two names of a rename may be a path. Windows has no directory
%% that means the working directory, so it refuses the pair.
write_at_mixed(Dir, TestDir) ->
    Path = filename:join(TestDir, "by_path"),
    ok = ?PRIM_FILE:write_file(filename:join(TestDir, "by_name"), "mixed"),

    case ?PRIM_FILE:rename({Dir, "by_name"}, Path) of
        ok ->
            {ok, <<"mixed">>} = ?PRIM_FILE:read_file(Path),
            ok = ?PRIM_FILE:rename(Path, {Dir, "by_name"}),
            {ok, <<"mixed">>} = ?PRIM_FILE:read_file({Dir, "by_name"});
        {error, enotsup} ->
            {win32, _} = os:type()
    end,

    ok = ?PRIM_FILE:delete({Dir, "by_name"}),
    ok.

%% Tests that make_link/2 and make_symlink/2 take a name in an open directory.
link_at(Config) ->
    RootDir = proplists:get_value(priv_dir, Config),
    TestDir = filename:join(RootDir, ?MODULE_STRING++"_link_at"),
    ok = ?PRIM_FILE:make_dir(TestDir),
    ok = ?PRIM_FILE:make_dir(filename:join(TestDir, "other")),
    ok = ?PRIM_FILE:write_file(filename:join(TestDir, "file"), "linked"),

    {ok, Dir} = ?PRIM_FILE:open(TestDir, [read, directory]),
    {ok, Other} = ?PRIM_FILE:open(filename:join(TestDir, "other"),
                                  [read, directory]),

    case ?PRIM_FILE:make_link({Dir, "file"}, {Dir, "hard"}) of
        {error, enotsup} ->
            ok;
        ok ->
            {ok, <<"linked">>} = ?PRIM_FILE:read_file({Dir, "hard"}),
            {ok, #file_info{links = 2}} = ?PRIM_FILE:read_file_info({Dir, "hard"}),

            %% The two names may belong to different open directories.
            ok = ?PRIM_FILE:make_link({Dir, "file"}, {Other, "hard"}),
            {ok, <<"linked">>} = ?PRIM_FILE:read_file({Other, "hard"}),

            %% Errors match what the matching path reports.
            {error, eexist} = ?PRIM_FILE:make_link({Dir, "file"}, {Dir, "hard"}),
            {error, enoent} = ?PRIM_FILE:make_link({Dir, "missing"}, {Dir, "x"}),

            %% One of the two names may be a path, where the operating system
            %% can do that.
            case ?PRIM_FILE:make_link({Dir, "file"},
                                      filename:join(TestDir, "by_path")) of
                ok ->
                    {ok, <<"linked">>} =
                        ?PRIM_FILE:read_file(filename:join(TestDir, "by_path")),
                    ok = ?PRIM_FILE:delete({Dir, "by_path"});
                {error, enotsup} ->
                    {win32, _} = os:type()
            end,

            ok = ?PRIM_FILE:delete({Other, "hard"}),
            ok = ?PRIM_FILE:delete({Dir, "hard"}),
            ok
    end,

    %% Only the new name of a symbolic link belongs to a directory. The target
    %% is stored in the link as it is given.
    case ?PRIM_FILE:make_symlink("file", {Dir, "soft"}) of
        {error, enotsup} ->
            ok;
        {error, eperm} ->
            {win32,_} = os:type(),
            ok;
        ok ->
            {ok, "file"} = ?PRIM_FILE:read_link({Dir, "soft"}),
            {ok, <<"linked">>} = ?PRIM_FILE:read_file({Dir, "soft"}),
            {ok, #file_info{type = symlink}} =
                ?PRIM_FILE:read_link_info({Dir, "soft"}),
            ok = ?PRIM_FILE:delete({Dir, "soft"}),
            ok
    end,

    ok = ?PRIM_FILE:close(Other),
    ok = ?PRIM_FILE:close(Dir),

    ok = ?PRIM_FILE:delete(filename:join(TestDir, "file")),
    ok = ?PRIM_FILE:del_dir(filename:join(TestDir, "other")),
    ok = ?PRIM_FILE:del_dir(TestDir),
    ok.

%% Tests that a name opened in a root cannot reach a file outside that root,
%% however the name is written.
open_in_root(Config) ->
    RootDir = proplists:get_value(priv_dir, Config),
    TestDir = filename:join(RootDir, ?MODULE_STRING++"_open_in_root"),
    ok = ?PRIM_FILE:make_dir(TestDir),

    %% The secret sits beside the root, so every escape below aims at it.
    Secret = filename:join(TestDir, "secret"),
    ok = ?PRIM_FILE:write_file(Secret, "SECRET"),

    Root = filename:join(TestDir, "root"),
    ok = ?PRIM_FILE:make_dir(Root),
    ok = ?PRIM_FILE:write_file(filename:join(Root, "inside"), "INSIDE"),
    ok = ?PRIM_FILE:make_dir(filename:join(Root, "sub")),

    {ok, R} = ?PRIM_FILE:open(Root, [read, directory]),

    %% A name that stays inside reaches the file it names.
    {ok, <<"INSIDE">>} = read_in_root(R, "inside"),
    {ok, <<"INSIDE">>} = ?PRIM_FILE:read_file({root, R, "inside"}),

    %% ".." is counted against how far the walk has moved below the root.
    {ok, <<"INSIDE">>} = read_in_root(R, "sub/../inside"),
    {ok, <<"INSIDE">>} = read_in_root(R, "sub/./../inside"),

    %% A ".." that would leave the root is refused.
    {error, exdev} = ?PRIM_FILE:open({root, R, "../secret"}, [read]),
    {error, exdev} = ?PRIM_FILE:open({root, R, "sub/../../secret"}, [read]),
    {error, exdev} = ?PRIM_FILE:open({root, R, ".."}, [read, directory]),

    %% An absolute name starts again at the root rather than at the file
    %% system root, so it names a file inside.
    {ok, <<"INSIDE">>} = read_in_root(R, "/inside"),
    {error, enoent} = ?PRIM_FILE:open({root, R, "/secret"}, [read]),

    %% A name that ends on a directory opens that directory.
    {ok, SubFd} = ?PRIM_FILE:open({root, R, "sub/"}, [read, directory]),
    ok = ?PRIM_FILE:close(SubFd),
    {ok, RootFd} = ?PRIM_FILE:open({root, R, "."}, [read, directory]),
    ok = ?PRIM_FILE:close(RootFd),

    %% A file is made in a root as it is in a directory.
    {ok, New} = ?PRIM_FILE:open({root, R, "sub/new"}, [write]),
    ok = ?PRIM_FILE:write(New, "NEW"),
    ok = ?PRIM_FILE:close(New),
    {ok, <<"NEW">>} = ?PRIM_FILE:read_file(filename:join([Root, "sub", "new"])),
    ok = ?PRIM_FILE:delete(filename:join([Root, "sub", "new"])),

    %% Errors match what a path reports.
    {error, enoent} = ?PRIM_FILE:open({root, R, "missing"}, [read]),
    {error, enotdir} = ?PRIM_FILE:open({root, R, "inside/x"}, [read]),
    {error, enametoolong} =
        ?PRIM_FILE:open({root, R, lists:duplicate(5000, $a)}, [read]),

    open_in_root_symlink(R, TestDir, Root),

    ok = ?PRIM_FILE:close(R),

    ok = ?PRIM_FILE:delete(filename:join(Root, "inside")),
    ok = ?PRIM_FILE:del_dir(filename:join(Root, "sub")),
    ok = ?PRIM_FILE:del_dir(Root),
    ok = ?PRIM_FILE:delete(Secret),
    ok = ?PRIM_FILE:del_dir(TestDir),
    ok.

read_in_root(R, Name) ->
    case ?PRIM_FILE:open({root, R, Name}, [read]) of
        {ok, Fd} ->
            Result = ?PRIM_FILE:read(Fd, 100),
            ok = ?PRIM_FILE:close(Fd),
            Result;
        Error ->
            Error
    end.

%% A symbolic link is followed by the walk itself, so a link that points out
%% of the root cannot be used to leave it.
open_in_root_symlink(R, TestDir, Root) ->
    Relative = filename:join(Root, "relative"),

    case relative_symlink(file, "../secret", Relative) of
        {error, enotsup} ->
            ok;
        {error, eperm} ->
            {win32,_} = os:type(),
            ok;
        ok ->
            %% The target of the link is resolved from the directory that
            %% holds the link, so it leaves the root and is refused.
            {error, exdev} = ?PRIM_FILE:open({root, R, "relative"}, [read]),

            %% Through a path, with no root, the same link reaches the secret.
            {ok, <<"SECRET">>} = ?PRIM_FILE:read_file(Relative),

            %% A link that stays inside is followed, and so is a link to it.
            ok = relative_symlink(file, "inside", filename:join(Root, "link")),
            ok = relative_symlink(file, "link", filename:join(Root, "link2")),
            {ok, <<"INSIDE">>} = read_in_root(R, "link"),
            {ok, <<"INSIDE">>} = read_in_root(R, "link2"),

            %% A link whose target leaves the root and comes back is refused,
            %% because the walk never leaves.
            ok = relative_symlink(file, "../root/inside",
                                  filename:join(Root, "out_and_back")),
            {error, exdev} = ?PRIM_FILE:open({root, R, "out_and_back"}, [read]),

            %% A cycle of links ends with eloop.
            ok = relative_symlink(file, "cycle_b", filename:join(Root, "cycle_a")),
            ok = relative_symlink(file, "cycle_a", filename:join(Root, "cycle_b")),
            {error, eloop} = ?PRIM_FILE:open({root, R, "cycle_a"}, [read]),
            {error, eloop} = ?PRIM_FILE:open({root, R, "cycle_a/x"}, [read]),

            %% An absolute target is reinterpreted against the root on Unix,
            %% where it names nothing, and refused outright on Windows.
            Absolute = filename:join(Root, "absolute"),
            ok = ?PRIM_FILE:make_symlink(filename:join(TestDir, "secret"),
                                         Absolute),
            case ?PRIM_FILE:open({root, R, "absolute"}, [read]) of
                {error, enoent} -> ok;
                {error, exdev} -> {win32,_} = os:type(), ok
            end,

            open_in_root_dir_symlink(R, Root),

            [ok = ?PRIM_FILE:delete(filename:join(Root, N))
             || N <- ["absolute", "cycle_a", "cycle_b", "out_and_back",
                      "link2", "link", "relative"]],
            ok
    end.

%% A link to a directory in the middle of a name is followed by the walk as
%% well, one link at a time.
open_in_root_dir_symlink(R, Root) ->
    ok = ?PRIM_FILE:write_file(filename:join([Root, "sub", "deep"]), "DEEP"),
    ok = relative_symlink(dir, "sub", filename:join(Root, "to_sub")),
    ok = relative_symlink(dir, "to_sub", filename:join(Root, "to_to_sub")),
    {ok, <<"DEEP">>} = read_in_root(R, "to_sub/deep"),
    {ok, <<"DEEP">>} = read_in_root(R, "to_to_sub/deep"),
    {ok, <<"INSIDE">>} = read_in_root(R, "to_sub/../inside"),

    %% A link to a directory outside is refused, wherever it sits.
    ok = relative_symlink(dir, "..", filename:join(Root, "up")),
    {error, exdev} = ?PRIM_FILE:open({root, R, "up/secret"}, [read]),
    {error, exdev} = ?PRIM_FILE:open({root, R, "to_sub/../up/secret"}, [read]),

    [ok = delete_symlink(dir, filename:join(Root, N))
     || N <- ["up", "to_to_sub", "to_sub"]],
    ok = ?PRIM_FILE:delete(filename:join([Root, "sub", "deep"])),
    ok.

%% prim_file:make_symlink/2 stores an absolute target on Windows, so a link
%% with a relative target is made with mklink there.
relative_symlink(Kind, Target, Link) ->
    case os:type() of
        {win32, _} ->
            Flag = case Kind of dir -> "/D "; file -> "" end,
            Cmd = "mklink " ++ Flag ++ quoted(Link) ++ " " ++ quoted(Target),
            Output = os:cmd(Cmd),
            case {string:find(Output, "<<===>>"), string:find(Output, "privilege")} of
                {nomatch, nomatch} -> ct:fail({Cmd, Output});
                {nomatch, _} -> {error, eperm};
                _ -> ok
            end;
        _ ->
            ?PRIM_FILE:make_symlink(Target, Link)
    end.

quoted(Path) ->
    "\"" ++ filename:nativename(Path) ++ "\"".

%% Windows removes a link to a directory as a directory.
delete_symlink(dir, Link) ->
    case os:type() of
        {win32, _} -> ?PRIM_FILE:del_dir(Link);
        _ -> ?PRIM_FILE:delete(Link)
    end.

%% Tests that every operation resolves a name in a root through the walk, so
%% that no operation reaches a file outside the root.
resolve_in_root(Config) ->
    RootDir = proplists:get_value(priv_dir, Config),
    TestDir = filename:join(RootDir, ?MODULE_STRING++"_resolve_in_root"),
    ok = ?PRIM_FILE:make_dir(TestDir),

    %% The secret sits beside the root, so every escape below aims at it.
    Secret = filename:join(TestDir, "secret"),
    ok = ?PRIM_FILE:write_file(Secret, "SECRET"),

    Root = filename:join(TestDir, "root"),
    ok = ?PRIM_FILE:make_dir(Root),
    ok = ?PRIM_FILE:write_file(filename:join(Root, "inside"), "INSIDE"),
    ok = ?PRIM_FILE:make_dir(filename:join(Root, "sub")),

    {ok, R} = ?PRIM_FILE:open(Root, [read, directory]),

    %% Reading a name.
    {ok, #file_info{type = regular, size = 6}} =
        ?PRIM_FILE:read_file_info({root, R, "inside"}),
    {ok, #file_info{type = regular}} =
        ?PRIM_FILE:read_file_info({root, R, "sub/../inside"}),
    {ok, #file_info{type = directory}} =
        ?PRIM_FILE:read_link_info({root, R, "sub"}),
    {ok, ["inside", "sub"]} = sorted(?PRIM_FILE:list_dir({root, R, "."})),
    {ok, []} = ?PRIM_FILE:list_dir({root, R, "sub"}),
    {ok, []} = ?PRIM_FILE:list_dir({root, R, "sub/"}),
    {error, exdev} = ?PRIM_FILE:read_file_info({root, R, "../secret"}),
    {error, exdev} = ?PRIM_FILE:list_dir({root, R, ".."}),
    {error, enoent} = ?PRIM_FILE:read_file_info({root, R, "missing"}),
    {error, enotdir} = ?PRIM_FILE:list_dir({root, R, "inside"}),

    %% Changing a name.
    ok = ?PRIM_FILE:make_dir({root, R, "sub/made"}),
    ok = ?PRIM_FILE:make_dir({root, R, "/top"}),
    {ok, #file_info{type = directory}} =
        ?PRIM_FILE:read_file_info(filename:join(Root, "top")),
    ok = ?PRIM_FILE:del_dir({root, R, "top"}),
    {error, exdev} = ?PRIM_FILE:make_dir({root, R, "../made"}),
    {error, exdev} = ?PRIM_FILE:make_dir({root, R, "sub/../../made"}),

    ok = ?PRIM_FILE:write_file(filename:join([Root, "sub", "made", "f"]), "F"),
    {error, exdev} = ?PRIM_FILE:delete({root, R, "sub/../../secret"}),
    ok = ?PRIM_FILE:rename({root, R, "sub/made/f"}, {root, R, "sub/g"}),
    {ok, <<"F">>} = ?PRIM_FILE:read_file({root, R, "sub/g"}),
    {error, exdev} = ?PRIM_FILE:rename({root, R, "sub/g"}, {root, R, "../g"}),
    {error, exdev} = ?PRIM_FILE:rename({root, R, "../secret"}, {root, R, "sub/g"}),
    ok = ?PRIM_FILE:delete({root, R, "sub/g"}),
    ok = ?PRIM_FILE:del_dir({root, R, "sub/made"}),

    {ok, Info} = ?PRIM_FILE:read_file_info({root, R, "inside"}),
    Time = {{2001, 2, 3}, {4, 5, 6}},
    ok = ?PRIM_FILE:write_file_info({root, R, "inside"},
                                    Info#file_info{mtime = Time}),
    {ok, #file_info{mtime = Time}} =
        ?PRIM_FILE:read_file_info(filename:join(Root, "inside")),
    {error, exdev} = ?PRIM_FILE:write_file_info({root, R, "../secret"}, Info),

    %% A name that resolves to the root itself is a directory that can be read
    %% or changed, but not removed, made or renamed.
    {ok, #file_info{type = directory}} =
        ?PRIM_FILE:read_file_info({root, R, "sub/.."}),
    {error, eisdir} = ?PRIM_FILE:delete({root, R, "."}),
    {error, eisdir} = ?PRIM_FILE:del_dir({root, R, "sub/.."}),
    {error, eisdir} = ?PRIM_FILE:make_dir({root, R, "."}),
    {error, eisdir} = ?PRIM_FILE:rename({root, R, "."}, {root, R, "x"}),

    resolve_in_root_links(R, TestDir, Root, Info),

    ok = ?PRIM_FILE:close(R),

    %% A closed root cannot hold a name.
    {error, einval} = ?PRIM_FILE:read_file_info({root, R, "inside"}),

    ok = ?PRIM_FILE:delete(filename:join(Root, "inside")),
    ok = ?PRIM_FILE:del_dir(filename:join(Root, "sub")),
    ok = ?PRIM_FILE:del_dir(Root),
    ok = ?PRIM_FILE:delete(Secret),
    ok = ?PRIM_FILE:del_dir(TestDir),
    ok.

sorted({ok, Names}) -> {ok, lists:sort(Names)};
sorted(Other) -> Other.

%% A copy of a raw file belongs to the process that made it.
dup(Config) ->
    RootDir = proplists:get_value(priv_dir, Config),
    TestDir = filename:join(RootDir, ?MODULE_STRING++"_dup"),
    ok = ?PRIM_FILE:make_dir(TestDir),
    ok = ?PRIM_FILE:write_file(filename:join(TestDir, "inside"), "INSIDE"),
    Log = filename:join(TestDir, "log"),

    %% Appends through a copy land in the same file.
    {ok, A} = ?PRIM_FILE:open(Log, [write, append]),
    ok = ?PRIM_FILE:write(A, "a"),
    ok = in_other_process(fun() ->
                                  {ok, B} = ?PRIM_FILE:dup(A),
                                  ok = ?PRIM_FILE:write(B, "b"),
                                  ?PRIM_FILE:close(B)
                          end),
    ok = ?PRIM_FILE:write(A, "c"),
    ok = ?PRIM_FILE:close(A),
    {ok, <<"abc">>} = ?PRIM_FILE:read_file(Log),

    %% A copy of a root is a root, and outlives the original.
    {ok, R} = ?PRIM_FILE:open_root(TestDir),
    {ok, R2} = in_other_process(fun() -> ?PRIM_FILE:dup(R) end),
    ok = ?PRIM_FILE:close(R),
    {ok, R3} = in_other_process(fun() -> ?PRIM_FILE:dup(R2) end),
    ok = in_other_process(fun() ->
                                  {ok, R4} = ?PRIM_FILE:dup(R3),
                                  {ok, <<"INSIDE">>} =
                                      ?PRIM_FILE:read_file({R4, "inside"}),
                                  {error, exdev} =
                                      ?PRIM_FILE:read_file({R4, "../x"}),
                                  ?PRIM_FILE:close(R4)
                          end),

    %% The copy belongs to its maker. Nobody else can use it.
    {'EXIT', {not_on_controlling_process, _}} =
        (catch ?PRIM_FILE:read_file({R2, "inside"})),
    {'EXIT', {not_on_controlling_process, _}} =
        (catch ?PRIM_FILE:read_file({R3, "inside"})),

    %% A closed original cannot be copied.
    {error, einval} = ?PRIM_FILE:dup(R),

    %% A read buffer would go stale.
    {ok, Buffered} = ?PRIM_FILE:open(Log, [read, read_ahead]),
    {error, badarg} = ?PRIM_FILE:dup(Buffered),
    ok = ?PRIM_FILE:close(Buffered),

    ok = ?PRIM_FILE:delete(Log),
    ok = ?PRIM_FILE:delete(filename:join(TestDir, "inside")),
    ok = ?PRIM_FILE:del_dir(TestDir),
    ok.

in_other_process(Fun) ->
    Parent = self(),
    {Pid, Ref} = spawn_monitor(fun() -> Parent ! {self(), Fun()},
                                        receive stop -> ok end
                               end),
    receive
        {Pid, Result} ->
            %% The process stays alive while the caller inspects the result,
            %% so a copy it made is not closed by its death yet.
            Ref2 = monitor(process, Pid),
            erlang:demonitor(Ref, [flush]),
            put({dup_process, Pid}, Ref2),
            Result;
        {'DOWN', Ref, process, Pid, Reason} ->
            ct:fail(Reason)
    end.

%% A root from open_root/1 makes {Root, Name} resolve as {root, Root, Name}.
open_root(Config) ->
    RootDir = proplists:get_value(priv_dir, Config),
    TestDir = filename:join(RootDir, ?MODULE_STRING++"_open_root"),
    ok = ?PRIM_FILE:make_dir(TestDir),
    ok = ?PRIM_FILE:write_file(filename:join(TestDir, "secret"), "SECRET"),
    Root = filename:join(TestDir, "root"),
    ok = ?PRIM_FILE:make_dir(Root),
    ok = ?PRIM_FILE:write_file(filename:join(Root, "inside"), "INSIDE"),

    {ok, R} = ?PRIM_FILE:open_root(Root),
    {ok, <<"INSIDE">>} = ?PRIM_FILE:read_file({R, "inside"}),
    {ok, <<"INSIDE">>} = ?PRIM_FILE:read_file({R, "/inside"}),
    {error, exdev} = ?PRIM_FILE:read_file({R, "../secret"}),
    {error, exdev} = ?PRIM_FILE:open({R, "../secret"}, [read]),
    {error, exdev} = ?PRIM_FILE:make_dir({R, "../dir"}),
    {ok, ["inside"]} = ?PRIM_FILE:list_dir({R, "."}),
    {ok, ["inside"]} = ?PRIM_FILE:list_dir(R),

    %% A root opened in a directory or in another root is a root as well.
    {ok, D} = ?PRIM_FILE:open(TestDir, [read, directory]),
    {ok, R2} = ?PRIM_FILE:open_root({D, "root"}),
    {error, exdev} = ?PRIM_FILE:read_file({R2, "../secret"}),
    {ok, R3} = ?PRIM_FILE:open_root({R, "."}),
    {error, exdev} = ?PRIM_FILE:read_file({R3, "../secret"}),
    {error, exdev} = ?PRIM_FILE:open_root({R, ".."}),
    {error, enotdir} = ?PRIM_FILE:open_root({R, "inside"}),

    ok = ?PRIM_FILE:close(R3),
    ok = ?PRIM_FILE:close(R2),
    ok = ?PRIM_FILE:close(D),
    ok = ?PRIM_FILE:close(R),

    ok = ?PRIM_FILE:delete(filename:join(Root, "inside")),
    ok = ?PRIM_FILE:del_dir(Root),
    ok = ?PRIM_FILE:delete(filename:join(TestDir, "secret")),
    ok = ?PRIM_FILE:del_dir(TestDir),
    ok.

%% An operation that acts on a link itself is given the link. An operation
%% that would follow the link has the walk follow it, so the link cannot lead
%% out of the root.
resolve_in_root_links(R, TestDir, Root, Info) ->
    Escape = filename:join(Root, "escape"),

    case relative_symlink(file, "../secret", Escape) of
        {error, enotsup} ->
            ok;
        {error, eperm} ->
            {win32,_} = os:type(),
            ok;
        ok ->
            {ok, #file_info{type = symlink}} =
                ?PRIM_FILE:read_link_info({root, R, "escape"}),
            %% Windows resolves a link to a full path, so the target is only
            %% checked for pointing at the file that was linked.
            {ok, EscapeTarget} = ?PRIM_FILE:read_link({root, R, "escape"}),
            "secret" = filename:basename(EscapeTarget),

            {error, exdev} = ?PRIM_FILE:read_file_info({root, R, "escape"}),
            {error, exdev} = ?PRIM_FILE:write_file_info({root, R, "escape"},
                                                        Info),
            {error, exdev} = ?PRIM_FILE:list_dir({root, R, "escape/"}),

            %% Through a path, with no root, the same link reaches the secret.
            {ok, #file_info{size = 6}} = ?PRIM_FILE:read_file_info(Escape),

            %% A link that stays inside is followed.
            ok = relative_symlink(file, "inside",
                                  filename:join(Root, "to_inside")),
            {ok, #file_info{type = regular, size = 6}} =
                ?PRIM_FILE:read_file_info({root, R, "to_inside"}),

            %% A link is removed as the link, not as what it points at.
            ok = ?PRIM_FILE:delete({root, R, "escape"}),
            {ok, #file_info{size = 6}} =
                ?PRIM_FILE:read_file_info(filename:join(TestDir, "secret")),

            %% A hard link is made in a root, with both names resolved through
            %% the walk. A symbolic link is made the same way where the
            %% platform can make one relative to a directory.
            ok = ?PRIM_FILE:make_link({root, R, "inside"}, {root, R, "hard"}),
            {ok, #file_info{links = 2}} =
                ?PRIM_FILE:read_file_info({root, R, "hard"}),
            {error, exdev} = ?PRIM_FILE:make_link({root, R, "../secret"},
                                                  {root, R, "hard2"}),
            {error, exdev} = ?PRIM_FILE:make_link({root, R, "inside"},
                                                  {root, R, "../hard2"}),
            ok = ?PRIM_FILE:delete({root, R, "hard"}),

            case ?PRIM_FILE:make_symlink("inside", {root, R, "soft"}) of
                ok ->
                    {ok, "inside"} = ?PRIM_FILE:read_link({root, R, "soft"}),
                    {error, exdev} =
                        ?PRIM_FILE:make_symlink("inside", {root, R, "../soft"}),
                    ok = ?PRIM_FILE:delete({root, R, "soft"});
                {error, enotsup} ->
                    {win32, _} = os:type()
            end,

            ok = ?PRIM_FILE:delete({root, R, "to_inside"}),
            ok
    end.

%%%
%%% Support for testing large files.
%%%

run_large_file_test(Config, Run, Name) ->
    case {erlang:system_info(wordsize),os:type(),os:version()} of
	{8,{win32,nt},_} ->
	    do_run_large_file_test(Config, Run, Name);
	{8,{unix,sunos},OsVersion} when OsVersion < {5,5,1} ->
	    {skip,"Only supported on Win32, Unix or SunOS >= 5.5.1"};
	{8,{unix,_},_} ->
	    DiscFree = unix_free(proplists:get_value(priv_dir, Config)),
            MemFree = free_memory(),
	    io:format("Free disk: ~w KByte~n", [DiscFree]),
	    io:format("Free mem: ~w MByte~n", [MemFree]),
	    if DiscFree < 5 bsl 20; MemFree < 5 bsl 10 ->
		    %% Less than 5 GByte free
		    {skip,"Less than 5 GByte free disk/mem"};
	       true ->
		    do_run_large_file_test(Config, Run, Name)
	    end;
	_ -> 
	    {skip,"Only supported on Win32, Unix or SunOS >= 5.5.1"}
    end.


do_run_large_file_test(Config, Run, Name0) ->
    Name = filename:join(proplists:get_value(priv_dir, Config),
			 ?MODULE_STRING ++ Name0),

    %% Set up a process that will delete this file.
    Tester = self(),
    Deleter = 
	spawn(
	  fun() ->
		  Mref = erlang:monitor(process, Tester),
		  receive
		      {'DOWN',Mref,_,_,_} -> ok;
		      {Tester,done} -> ok
		  end,
		  ?PRIM_FILE:delete(Name)
	  end),

    %% Run the test case.
    Res = Run(Name),

    %% Delete file and finish deleter process.
    Mref = erlang:monitor(process, Deleter),
    Deleter ! {Tester,done},
    receive {'DOWN',Mref,_,_,_} -> ok end,

    Res.

unix_free(Path) ->
    Cmd = ["df -k '",Path,"'"],
    DF0 = os:cmd(Cmd),
    io:format("$ ~s~n~s", [Cmd,DF0]),
    Lines = re:split(DF0, "\n", [trim,{return,list}]),
    Last = lists:last(Lines),
    RE = "^[^\\s]*\\s+\\d+\\s+\\d+\\s+(\\d+)",
    {match,[Avail]} = re:run(Last, RE, [{capture,all_but_first,list}]),
    list_to_integer(Avail).

zip_data([A|As], [B|Bs]) ->
    [[A,B]|zip_data(As, Bs)];
zip_data([], Bs) ->
    Bs;
zip_data(As, []) ->
    As.

%% Stolen from emulator -> alloc_SUITE
free_memory() ->
    %% Free memory in MB.
    try
	SMD = memsup:get_system_memory_data(),
	{value, {free_memory, Free}} = lists:keysearch(free_memory, 1, SMD),
	TotFree = (Free +
		   case lists:keysearch(cached_memory, 1, SMD) of
		       {value, {cached_memory, Cached}} -> Cached;
		       false -> 0
		   end +
		   case lists:keysearch(buffered_memory, 1, SMD) of
		       {value, {buffered_memory, Buffed}} -> Buffed;
		       false -> 0
		   end),
	usable_mem(TotFree) div (1024*1024)
    catch
	error : undef ->
	    ct:fail({"os_mon not built"})
    end.

usable_mem(Memory) ->
    case test_server:is_valgrind() of
        true ->
            %% Valgrind uses extra memory for the V- and A-bits.
            %% http://valgrind.org/docs/manual/mc-manual.html#mc-manual.value
            %% Docs says it uses "compression to represent the V bits compactly"
            %% but let's be conservative and cut usable memory in half.
            Memory div 2;
        false ->
            Memory
    end.


%%%-----------------------------------------------------------------
%%% Utilities
rm_rf(Mod,Dir) ->
    case  Mod:read_link_info(Dir) of
	{ok, #file_info{type = directory}} ->
	    {ok, Content} = Mod:list_dir_all(Dir),
	    [ rm_rf(Mod,filename:join(Dir,C)) || C <- Content ],
	    Mod:del_dir(Dir),
	    ok;
	{ok, #file_info{}} ->
	    Mod:delete(Dir);
	_ ->
	    ok
    end.
