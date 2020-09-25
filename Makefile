yamllint:
	docker run --rm -ti -v $(shell pwd):/docker-amqproxy -w /docker-amqproxy/ci teamleader/yamllint:latest . -d .yamllint

fly-validate:
	docker run --rm -ti -v $(shell pwd):/docker-amqproxy -w /docker-amqproxy/ci teamleader/concourse-fly:6.2

set-pipeline:
	fly -t tl set-pipeline -p docker-amqproxy -c ci/pipeline.yaml -l ci/params.yaml -l ci/common-vars.yaml
