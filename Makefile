.PHONY: test benchmark signing app qa-app qa-verify qa-install dmg verify install clean

test:
	arch -arm64 /usr/bin/swift test --arch arm64

benchmark:
	arch -arm64 /usr/bin/swift run -c release --arch arm64 PasteoryBenchmark

signing:
	./scripts/ensure_local_signing_identity.sh >/dev/null
	@echo "Pasteory 稳定本地签名身份已就绪"

app:
	./scripts/build_app.sh

qa-app:
	./scripts/build_qa_app.sh

qa-verify: app qa-app
	./scripts/verify_qa_isolation.sh

qa-install: qa-app
	./scripts/install_qa.sh

dmg: app
	./scripts/package_dmg.sh

verify: dmg
	./scripts/verify.sh

install: app
	./scripts/install.sh

clean:
	arch -arm64 /usr/bin/swift package clean
	rm -rf dist
