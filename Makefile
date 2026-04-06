.PHONY: help build clean release deploy

PROJECT  = ParentalThingsClient.xcodeproj
SCHEME   = ParentalThingsClient
DEST     = platform=macOS
APP_NAME = ParentalThingsClient.app
BUILD_DIR = $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' -configuration Release -showBuildSettings 2>/dev/null | grep ' BUILT_PRODUCTS_DIR =' | sed 's/.*= //')
VERSION  = $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' -configuration Release -showBuildSettings 2>/dev/null | grep ' MARKETING_VERSION =' | sed 's/.*= //')

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

build: ## Build the project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' -configuration Release build

clean: ## Clean build artifacts
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean

deploy: build ## Build and copy app to admin desktops
	@echo "Deploying $(APP_NAME) v$(VERSION)..."
	cp -R "$(BUILD_DIR)/$(APP_NAME)" "/Volumes/admin/Desktop/$(APP_NAME)"
	cp -R "$(BUILD_DIR)/$(APP_NAME)" "/Volumes/admin-1/Desktop/$(APP_NAME)"
	@echo "Deployed to /Volumes/admin/Desktop and /Volumes/admin-1/Desktop"

release: deploy ## Build, deploy, and create GitHub release
	@echo "Creating GitHub release v$(VERSION)..."
	cd "$(BUILD_DIR)" && zip -r "$(APP_NAME:.app=)-v$(VERSION).zip" "$(APP_NAME)"
	gh release create "v$(VERSION)" \
		"$(BUILD_DIR)/$(APP_NAME:.app=)-v$(VERSION).zip" \
		--title "v$(VERSION)" \
		--notes "ParentalThingsClient v$(VERSION)"
	@echo "Released v$(VERSION): https://github.com/greg-savage/ParentalThingsAgent/releases/tag/v$(VERSION)"
