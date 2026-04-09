.PHONY: build test lint

build:
	rebar3 escriptize

test:
	rebar3 ct

lint:
	rebar3 lint
	rebar3 dialyzer
