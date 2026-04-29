# PureScript Playground — orchestration
#
# Targets:
#   bootstrap    build everything (workspace build + frontend bundle)
#   build        spago build at workspace root
#   bundle       bundle the frontend to public/bundle.js
#   start        start backend (3050) and frontend (3051) in the background
#   stop         kill services running on the configured ports
#   status       show port occupancy
#   clean        remove build artefacts

BACKEND_PORT  ?= 3050
FRONTEND_PORT ?= 3051
TRYPS_PORT    ?= 8081

.PHONY: help bootstrap build bundle start stop status clean

help:
	@echo "PureScript Playground"
	@echo ""
	@echo "  make bootstrap     Build workspace + bundle frontend"
	@echo "  make build         spago build (workspace)"
	@echo "  make bundle        Bundle frontend to public/bundle.js"
	@echo "  make start         Run backend + frontend"
	@echo "  make stop          Stop both"
	@echo "  make status        Show port occupancy"
	@echo "  make clean         Remove build artefacts"
	@echo ""
	@echo "  Ports: backend=$(BACKEND_PORT) frontend=$(FRONTEND_PORT) trypurescript=$(TRYPS_PORT)"

bootstrap: build bundle
	@echo "Bootstrap complete."

# Explicitly build only the three packages we maintain directly.
# `playground-runtime` is user-facing scratch space — its Main.purs is
# overwritten by the backend on every compile, so we don't try to build
# it from the command line here (a stale broken Main would wedge the
# whole workspace build).
build:
	spago build -p playground-shared
	spago build -p playground-server
	spago build -p playground-frontend

bundle:
	spago bundle -p playground-frontend

start: bootstrap
	@echo "Starting backend on :$(BACKEND_PORT) and frontend on :$(FRONTEND_PORT)"
	@node server/run.js > /tmp/playground-backend.log 2>&1 &
	@npx http-server frontend/public -p $(FRONTEND_PORT) -c-1 --cors > /tmp/playground-frontend.log 2>&1 &
	@sleep 1
	@echo "Backend log:  /tmp/playground-backend.log"
	@echo "Frontend log: /tmp/playground-frontend.log"
	@echo "Open http://localhost:$(FRONTEND_PORT)"

stop:
	-@lsof -ti :$(BACKEND_PORT)  | xargs -r kill 2>/dev/null || true
	-@lsof -ti :$(FRONTEND_PORT) | xargs -r kill 2>/dev/null || true
	@echo "Stopped."

status:
	@echo "backend  ($(BACKEND_PORT)):      $$(lsof -ti :$(BACKEND_PORT)  2>/dev/null || echo '(not running)')"
	@echo "frontend ($(FRONTEND_PORT)):      $$(lsof -ti :$(FRONTEND_PORT) 2>/dev/null || echo '(not running)')"
	@echo "trypurescript ($(TRYPS_PORT)): $$(lsof -ti :$(TRYPS_PORT) 2>/dev/null || echo '(not running)')"

clean:
	rm -rf output .spago frontend/public/bundle.js
