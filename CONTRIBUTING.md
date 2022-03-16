# Contributing

_TODO_

## Release

1. Update `CHANGELOG.md`
1. Bump version in `shards.yml`
1. Create and push an annotated tag: `git tag -a v$(shards version)`
    1. Put the changelog of the version in the tagging message
    1. **NOTE**: Only the `body` will be shown in [release notes]. (The first line in the message is the `subject` followed by an empty line, then the `body` on the next line.)

[release notes]: https://github.com/cloudamqp/amqproxy/releases
