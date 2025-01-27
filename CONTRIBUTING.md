# Contributing to format_parser

Please take a moment to review this document in order to make the contribution
process easy and effective for everyone involved.

Following these guidelines helps to communicate that you respect the time of
the developers managing and developing this open source project. In return,
they should reciprocate that respect in addressing your issue or assessing
patches and features.

## What do I need to know to help?

If you are already familiar with the [Ruby Programming Language](https://www.ruby-lang.org/) you can start contributing code right away, otherwise look for issues labeled with *documentation* or *good first issue* to get started.

If you are interested in contributing code and would like to learn more about the technologies that we use, check out the (non-exhaustive) list below. You can also get in touch with us via an issue or email to julik@wetransfer.com and/or noah@wetransfer.com to get additional information.

 - [ruby](https://ruby-doc.org)
 - [rspec](http://rspec.info/) (for testing)

# How do I make a contribution?

## Using the issue tracker

The issue tracker is the preferred channel for [bug reports](#bug-reports),
[feature requests](#feature-requests) and [submitting pull
requests](#pull-requests), but please respect the following restrictions:

* Please **do not** derail or troll issues. Keep the discussion on topic and respect the opinions of others. Adhere to the principles set out in the [Code of Conduct](https://github.com/WeTransfer/format_parser/blob/master/CODE_OF_CONDUCT.md).

## Bug reports

A bug is a _demonstrable problem_ that is caused by code in the repository.

Good bug reports are extremely helpful-thank you!

Guidelines for bug reports:

1. **Use the GitHub issue search** – check if the issue has already been
   reported.

2. **Check if the issue has been fixed** – try to reproduce it using the
   latest `master` branch in the repository.

3. **Isolate the problem** – create a [reduced test
   case](http://css-tricks.com/reduced-test-cases/) and a live example.

A good bug report shouldn't leave others needing to chase you up for more
information. Please try to be as detailed as possible in your report. What is
your environment? What steps will reproduce the issue? What tool(s) or OS will
experience the problem? What would you expect to be the outcome? All these
details will help people to fix any potential bugs.

Example:

> Short and descriptive example bug report title
>
> A summary of the issue and the OS environment in which it occurs. If
> suitable, include the steps required to reproduce the bug.
>
> 1. This is the first step
> 2. This is the second step
> 3. Further steps, etc.
>
> `<url>` - a link to the reduced test case, if possible. Feel free to use a [Gist](https://gist.github.com).
>
> Any other information you want to share that is relevant to the issue being
> reported. This might include the lines of code that you have identified as
> causing the bug, and potential solutions (and your opinions on their
> merits).

## Feature requests

Feature requests are welcome. But take a moment to find out whether your idea
fits with the scope and aims of the project. It's up to *you* to make a strong
case to convince the project's developers of the merits of this feature. Please
provide as much detail and context as possible.

## So, you want to contribute a new parser

That's awesome! Please do take care to add example files that fit your parser use case.
Make sure that the file you are adding is licensed for use within an MIT-licensed piece
of software. Ideally, this file is going to be something you have produced yourself
and you are permitted to share under the MIT license provisions.

When writing a parser, please try to ensure it returns a usable result as soon as possible,
or `nil` as soon as possible (once you know the file is not fit for your specific parser).
Bear in mind that we enforce read budgets per-parser, so you will not be allowed to perform
too many reads, or perform reads which are too large.

In order to create new parsers, make a well-named class with an instance method `call`,
and to register a single instance of that class as the parser - so that only one object needs to be stored
in memory when parsing multiple inputs. In that case your object must be **thread-safe and stateless** - this
is really important since FormatParser is thread-safe and multiple parsing procedures may be in progress
concurrently against the same parser object. You can also create a Proc if your parser is fairly trivial.

If it will be difficult to have your parser thread-safe you can register your class itself as
the parser and define the `self.call` method to parse using a fresh instance every time, allowing
object-level state:

```ruby
class MyParser
  def self.call(io)
    new.call(io)
  end

  def call(io)
    @state = ...
  end
```

`call` accepts a single argument - an IO-ish object which is guaranteed to respond to the same methods as the
ones defined in `IOConstraint` - that is, it is a strict subset of a standard Ruby IO object. *All reads from
this IO object are guaranteed to be returned in binary encoding.* The IO will be at offset of 0 when your parsing
proc receives it and there will be no concurrent calls to that object until your proc returns.

Your parsing procedure may read from this IO object, and should return either a `Result`-like object with
the file metadata (if it could recover any) or `nil` if it couldn't. All files pass
through all parsers by default, so if you are dealing with a file that is not "your" format - return `nil` from
your method or `break` your Proc as early as possible. A blank `return` works fine too as it actually returns `nil`.

Your parser then needs to be registered using `FormatParser.register_parser` with the information on the formats
and file natures it provides. This allows FormatParser to skip your parser if, say, the user only want to parse for
`:image` nature files but your parser parses `:audio`.

Down below you can find the most basic parser implementation which parses an imaginary `IMGA` file format:

```ruby
MyParser = ->(io) {
  # ... Read the magic bytes from the start of IO - the IO is
  # guaranteed to be fed to you at offset 0, start-of-file.
  magic_bytes = io.read(4)

  # breaking the block returns `nil` to the caller signaling "no match"
  break if magic_bytes != 'IMGA'

  # Our file format stores the width and height as 2 32-bit unsigned integers
  parsed_witdh, parsed_height = io.read(8).unpack('VV')

  # ...and return the FileInformation::Image object with the metadata.
  FormatParser::Image.new(
    format: :imga,
    width_px: parsed_width,
    height_px: parsed_height,
  )
}

# Register the parser with the module, so that it will be applied to any
# document given to `FormatParser.parse()`. The supported natures are currently
#      - :audio
#      - :document
#      - :image
#      - :video
#      - :archive
FormatParser.register_parser MyParser, natures: :image, formats: :imga
```

If you are using a class, this is the skeleton to use:

```ruby
class MyParser
  def call(io)
    # ... do some parsing with `io`
    # The instance will be discarded after parsing, so using instance variables
    # is permitted - they are not shared between calls to `call`
    magic_bytes = io.read(4)
    break if magic_bytes != 'IMGA'
    parsed_witdh, parsed_height = io.read(8).unpack('VV')
    FormatParser::Image.new(
      format: :imga,
      width_px: parsed_width,
      height_px: parsed_height,
    )
  end

  # Note that we register an instance of the class, not the class. It is the
  # instance that responds to `call()` and we can do this because our object
  # is stateless.
  FormatParser.register_parser new, natures: :image, formats: :bmp
end
```

If your parser supports file types which have a known filename extension, you can add a method to it called `likely_match?`,
add this method on the object you register itself. For example, for the ZIP parser we use:

```ruby
  def likely_match?(filename)
    filename =~ /\.(zip|docx|keynote|numbers|pptx|xlsx)$/i
  end
```

If your parser matches the filename it is going to be applied *earlier*, saving time. Since most FormatParser users are
likely to only want the first result of the parsing, the sooner your parser gets applied - the sooner you can return the result,
avoiding unnecessary reads.

### Calling convention for preparing parsers

A parser that gets registered using `register_parser` must be an object that can be `call()`-ed, with an argument that conforms to `IOConstraint`

FormatParser is made to be used in threaded environments, and if you use instance variables
you need your parser to be isolated from it's siblings in other threads - create a copy for one-off use inside
your `call` method.

## Pull requests

Good pull requests-patches, improvements, new features-are a fantastic
help. They should remain focused in scope and avoid containing unrelated
commits.

**Please ask first** before embarking on any significant pull request (e.g.
implementing features, refactoring code, porting to a different language),
otherwise you risk spending a lot of time working on something that the
project's developers might not want to merge into the project.

Please adhere to the coding conventions used throughout the project (indentation,
accurate comments, etc.) and any other requirements (such as test coverage).

The test suite can be run with `bundle exec rspec`.

Follow this process if you'd like your work considered for inclusion in the
project:

1. [Fork](http://help.github.com/fork-a-repo/) the project, clone your fork,
   and configure the remotes:

   ```bash
   # Clone your fork of the repo into the current directory
   git clone git@github.com:WeTransfer/format_parser.git
   # Navigate to the newly cloned directory
   cd format_parser
   # Assign the original repo to a remote called "upstream"
   git remote add upstream git@github.com:WeTransfer/format_parser.git
   ```

2. If you cloned a while ago, get the latest changes from upstream:

   ```bash
   git checkout <dev-branch>
   git pull upstream <dev-branch>
   ```

3. Create a new topic branch (off the main project development branch) to
   contain your feature, change, or fix:

   ```bash
   git checkout -b <topic-branch-name>
   ```

4. Commit your changes in logical chunks and/or squash them for readability and
   conciseness. Check out [this post](https://chris.beams.io/posts/git-commit/) or
   [this other post](http://tbaggery.com/2008/04/19/a-note-about-git-commit-messages.html) for some tips re: writing good commit messages.

5. Locally merge (or rebase) the upstream development branch into your topic branch:

   ```bash
   git pull [--rebase] upstream <dev-branch>
   ```

6. Push your topic branch up to your fork:

   ```bash
   git push origin <topic-branch-name>
   ```

7. [Open a Pull Request](https://help.github.com/articles/using-pull-requests/)
    with a clear title and description.

**IMPORTANT**: By submitting a patch, you agree to allow the project owner to
license your work under the same license as that used by the project, which you
can see by clicking [here](https://github.com/WeTransfer/format_parser/blob/master/LICENSE.txt).
This provision also applies to the test files you include with the changed code as fixtures.

## Changelog

When creating a new release you must add an entry in the `CHANGELOG.md`.

## Testing locally

It's possible to run `exe/format_parser_inspect FILE_NAME` or `exe/format_parser_inspect FILE_URI`
to test the new code without the necessity of installing the gem.
