# CountdownOverlay — everything needs only the Xcode command-line tools.
#   make build    compile the bare binary (build/CountdownOverlay)
#   make app      assemble + ad-hoc sign build/CountdownOverlay.app (and the .zip)
#   make run      build the app and open it
#   make install  install into ~/Applications (same place install.sh uses) and open it
#   make clean

NAME := CountdownOverlay
APP  := build/$(NAME).app
DEST := $(HOME)/Applications/$(NAME).app

.PHONY: build app run install clean

build:
	mkdir -p build
	swiftc -O -o build/$(NAME) main.swift -framework Cocoa

app:
	scripts/make-app.sh

run: app
	open $(APP)

install: app
	pkill -x $(NAME) 2>/dev/null; sleep 1; true
	mkdir -p $(HOME)/Applications
	rm -rf "$(DEST)"
	ditto $(APP) "$(DEST)"
	open "$(DEST)"
	@echo "Installed to $(DEST)"

clean:
	rm -rf ./build
