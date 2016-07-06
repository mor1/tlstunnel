.PHONY: all build clean

all: build

build:
	./build.sh lib

clean:
	./build.sh clean
