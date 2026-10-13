# Yandex Cloud ingress

A Cloud Function that relays `/v1/*` to the production API. It exists for
networks where the Vercel hostnames stall (see
`docs/verification/network-audit-1.2.0.md`); the app reaches it as one more
route in `PADELID_API_FALLBACK_URL`.

The function holds no database credential. Its only setting is
`PADELID_RELAY_KEY`, the same value as on the API, so that the API limits
sign-in, sign-up, refresh and recovery by the caller's address instead of by
the function's. Without the key every user behind the function shares one
budget.

## Build

```sh
cd server && node scripts/build-yandex.mjs   # deploy/yandex/build/function.zip
```

Runtime `nodejs22`, entry point `yandex-function.handler`, 128 MB, timeout 20 s.

## Deploy

```sh
yc serverless function create --name padel-id-ingress
yc serverless function version create --function-name padel-id-ingress \
  --runtime nodejs22 --entrypoint yandex-function.handler \
  --memory 128m --execution-timeout 20s \
  --source-path deploy/yandex/build/function.zip \
  --environment PADELID_RELAY_KEY=<value set on the API>
yc serverless function allow-unauthenticated-invoke padel-id-ingress
```

The function then answers at `https://functions.yandexcloud.net/<function id>/v1/health`.
`api-gateway.yaml` puts an API Gateway hostname in front of it when a stable
name or a custom domain is wanted; the gateway has a smaller free allowance.

## Cost

Billed per call and per GB×hour of execution, with a monthly free allowance
(1,000,000 calls and 10 GB×hour at the time of writing; API Gateway: 100,000
requests). A budget in Yandex Cloud Billing only notifies — it does not stop
anything — so set one with a low threshold and keep the function's instance
limit small. Check the current price list before relying on these numbers.

## Checks after deployment

- `GET /v1/health` returns the production JSON with `x-padelid-edge-mode: relay`.
- `GET /v1/me` without a session returns 401 from the API.
- Anything outside `/v1/` returns 404 from the function itself.
- From the owner's phone without VPN, on home Wi-Fi and on mobile data.
