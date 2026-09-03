APP_NAME    := ClipBridge
BUNDLE      := $(APP_NAME).app
BUILD_DIR   := .build/release
DIST_DIR    := dist
CONFIG      := release

.PHONY: all build app run clean zip install

all: app

build:
	swift build -c $(CONFIG) --arch arm64 --arch x86_64

## .app バンドルを組み立てる
app: build
	rm -rf "$(DIST_DIR)/$(BUNDLE)"
	mkdir -p "$(DIST_DIR)/$(BUNDLE)/Contents/MacOS"
	mkdir -p "$(DIST_DIR)/$(BUNDLE)/Contents/Resources"
	cp Resources/Info.plist "$(DIST_DIR)/$(BUNDLE)/Contents/Info.plist"
	@# universal binary は .build/apple/Products/Release に出る
	@if [ -f ".build/apple/Products/Release/$(APP_NAME)" ]; then \
		cp ".build/apple/Products/Release/$(APP_NAME)" "$(DIST_DIR)/$(BUNDLE)/Contents/MacOS/$(APP_NAME)"; \
	else \
		cp "$(BUILD_DIR)/$(APP_NAME)" "$(DIST_DIR)/$(BUNDLE)/Contents/MacOS/$(APP_NAME)"; \
	fi
	printf 'APPL????' > "$(DIST_DIR)/$(BUNDLE)/Contents/PkgInfo"
	@# ad-hoc 署名。Apple Developer 証明書があれば CODESIGN_ID を指定
	codesign --force --deep --sign "$${CODESIGN_ID:--}" "$(DIST_DIR)/$(BUNDLE)"
	@echo ""
	@echo "✅ $(DIST_DIR)/$(BUNDLE) を作成しました"
	@echo "   open $(DIST_DIR)/$(BUNDLE) で起動できます"

run: app
	open "$(DIST_DIR)/$(BUNDLE)"

## /Applications にインストール
install: app
	rm -rf "/Applications/$(BUNDLE)"
	cp -R "$(DIST_DIR)/$(BUNDLE)" /Applications/
	@echo "✅ /Applications/$(BUNDLE) にインストールしました"

## 配布用 zip
zip: app
	cd "$(DIST_DIR)" && ditto -c -k --keepParent "$(BUNDLE)" "$(APP_NAME).zip"
	@echo "✅ $(DIST_DIR)/$(APP_NAME).zip"

clean:
	rm -rf .build "$(DIST_DIR)"
