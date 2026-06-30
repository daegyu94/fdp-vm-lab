.PHONY: bringup no-ssh with-lmcache status stop clean full-clean rebuild-warp rebuild-guest

bringup:
	./bringup.sh

no-ssh:
	./bringup.sh --no-ssh

with-lmcache:
	./bringup.sh --with-lmcache

status:
	./bringup.sh --status

stop:
	./bringup.sh --stop

clean:
	./bringup.sh --clean

full-clean:
	./bringup.sh --full-clean

rebuild-warp:
	./bringup.sh --rebuild-warp

rebuild-guest:
	./bringup.sh --rebuild-guest

