# Contributing

## Development

Run tests in Docker:

```bash
docker build  . -f spec/Dockerfile -t amqproxy_spec
docker run --rm -it -v $(pwd):/app -w /app --entrypoint bash amqproxy_spec

# ensure rabbitmq is up, run all specs
./entrypoint.sh

# run single spec
crystal spec --example "keeps connections open"
```

Run tests using Docker Compose:

```bash
./run-specs-in-docker.sh
```

## Release

1. Make a commit that
    1. updates `CHANGELOG.md`
    1. bumps version in `shard.yml`
1. Create and push an annotated tag: `git tag -a v$(shards version)`
    1. Put the changelog of the version in the tagging message
    1. **NOTE**: Only the `body` will be shown in [release notes]. (The first line in the message is the `subject` followed by an empty line, then the `body` on the next line.)

[release notes]: https://github.com/cloudamqp/amqproxy/releases
