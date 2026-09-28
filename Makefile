.PHONY: test

# spec はモジュールの隣（lua/**/*_spec.lua）にコロケーションする。tests/ は統合テスト用
test:
	nvim --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory . {minimal_init = 'tests/minimal_init.lua'}"
