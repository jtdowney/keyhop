proto:
    buf generate
    gleam format src/migration.gleam

build: proto
    pnpm run build

dev: proto
    pnpm run dev
