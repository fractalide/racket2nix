In racket2nix, as in fractalide generally, we follow the [C4](C4.md)
process. Read that document. It's not even very long, but if you
really want to understand the spirit and meaning behind the words (we
think this is a good idea), do read the
[annotated version](http://zguide.zeromq.org/page:all#The-ZeroMQ-Process-C)
as well.

TL;DR: You own your code, you give it to us as an equal, under the
[project license](LICENSE), every change to the codebase is via a pull
request, no exceptions. Correct changes (passes tests, solves a
specific problem, follows commit message and code standard) will be
merged swiftly. Once you have given us code, you are us. Commit bit is
given liberally, but comes with the responsibility to uphold the above
process and ideals.

Here are the specifics for what you need to to when writing your PR:

 - Run `make`. This will generate a new `default.nix` using
   `racket2nix` itself, after verifying that `racket2nix` still
   packages and works with the new changes.

That's basically it. Join us, and make racket, nix and the future of
programming better!
