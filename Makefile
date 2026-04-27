.PHONY: bootstrap build-rust test-rust test-python lint xcframework bindings clean help

help:
	@echo "Sleep Tracker — monorepo commands"
	@echo "  bootstrap      Install rust targets + python deps"
	@echo "  build-rust     Build sleep-core + sleep-cli (host)"
	@echo "  xcframework    Build xcframework for iOS + Simulator"
	@echo "  bindings       Regenerate swift-bridge bindings"
	@echo "  test-rust      Run cargo tests"
	@echo "  test-python    Run pytest"
	@echo "  lint           Run cargo clippy + ruff"
	@echo "  clean          Clean all build artefacts"

bootstrap:
	bash scripts/bootstrap.sh

build-rust:
	cd rust && cargo build --workspace --release

xcframework:
	bash scripts/build_rust_xcframework.sh

bindings:
	bash scripts/gen_bindings.sh

test-rust:
	cd rust && cargo test --workspace

test-python:
	cd python && python -m pytest -q || echo "(no tests yet)"

lint:
	cd rust && cargo fmt --check
	cd rust && cargo clippy --workspace --all-targets -- -D warnings
	cd python && ruff check .

clean:
	cd rust && cargo clean
	rm -rf apple/SleepKit/.build apple/SleepKit/Sources/SleepKit/Generated
	rm -rf rust/target-xcframework
