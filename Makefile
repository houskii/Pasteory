.PHONY: test benchmark app dmg verify install clean

test:
	arch -arm64 /usr/bin/swift test --arch arm64

benchmark:
	arch -arm64 /usr/bin/swift run -c release --arch arm64 PassteBenchmark

app:
	./scripts/build_app.sh

dmg: app
	./scripts/package_dmg.sh

verify: dmg
	./scripts/verify.sh

install: app
	./scripts/install.sh

clean:
	arch -arm64 /usr/bin/swift package clean
	rm -rf dist
