# keyhop

Move TOTP accounts out of Google Authenticator into any other authenticator app.

## How it works

Scan your Google Authenticator export with a camera, then present each account
as a standard `otpauth://` QR code that any authenticator app can scan.

Google Authenticator shows the export on the phone that holds your accounts, so
that phone cannot scan its own screen. Scan it with a second device.

## Development

```sh
pnpm install
pnpm dev     # gleam build + vite dev server
```
