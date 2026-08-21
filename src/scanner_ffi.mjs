import { readBarcodes, setZXingModuleOverrides } from "zxing-wasm/reader";

import { is_otpauth_uri as isOtpauthUri } from "./accounts.mjs";
import {
  Error$CameraFailed,
  Error$CameraInUse,
  Error$InsecureContext,
  Error$NoCameraFound,
  Error$PermissionDenied,
  Error$ScannerUnavailable,
} from "./scanner.mjs";

const DECODE_FAILURE_LIMIT = 5;
const DECODE_INTERVAL_MS = 120;

function scanError(err) {
  switch (err?.name) {
    case "NotAllowedError":
      return Error$PermissionDenied();
    case "NotFoundError":
      return Error$NoCameraFound();
    case "NotReadableError":
      return Error$CameraInUse();
    default:
      return Error$CameraFailed(err?.name ?? String(err));
  }
}

let wasmReady = null;

function configureWasm() {
  if (wasmReady === null) {
    wasmReady = import("zxing-wasm/reader/zxing_reader.wasm?url")
      .then(({ default: url }) =>
        setZXingModuleOverrides({ locateFile: () => url }),
      )
      .catch((e) => {
        wasmReady = null;
        throw e;
      });
  }

  return wasmReady;
}

let activeScan = null;

export function clearLastSent() {
  if (activeScan) {
    activeScan.lastSent = null;
  }

  return undefined;
}

async function decodeImageData(image, session, scanGeneration, onDecode) {
  await configureWasm();

  const results = await readBarcodes(image, {
    formats: ["QRCode"],
    tryHarder: true,
  });

  if (session !== activeScan) {
    return;
  }

  const text = results[0]?.text;
  if (text && isOtpauthUri(text) && text !== session.lastSent) {
    session.lastSent = text;
    onDecode(scanGeneration, text);
  }
}

export function start(scanGeneration, onDecode, onError) {
  stop();

  if (!navigator.mediaDevices) {
    onError(Error$InsecureContext());
    return undefined;
  }

  const video = document.createElement("video");
  video.setAttribute("playsinline", "true");
  const canvas = document.createElement("canvas");
  const ctx = canvas.getContext("2d", { willReadFrequently: true });

  const session = { video, stream: null, frameId: null, lastSent: null };
  activeScan = session;

  let decoding = false;
  let decodeFailures = 0;
  let lastDecodeAt = 0;

  navigator.mediaDevices
    .getUserMedia({
      video: {
        facingMode: "environment",
      },
    })
    .then(async (s) => {
      if (session !== activeScan) {
        for (const track of s.getTracks()) {
          track.stop();
        }

        return;
      }

      session.stream = s;
      video.srcObject = s;

      // Front and desktop cameras read as a mirror; rear cameras must not.
      if (s.getVideoTracks()[0]?.getSettings().facingMode !== "environment") {
        video.style.transform = "scaleX(-1)";
      }

      const preview = document.getElementById("camera-preview");
      if (preview) {
        preview.appendChild(video);
      }

      await video.play();

      if (session !== activeScan) {
        return;
      }

      const tick = (now) => {
        if (session !== activeScan) {
          return;
        }

        if (
          !decoding &&
          now - lastDecodeAt >= DECODE_INTERVAL_MS &&
          video.readyState === video.HAVE_ENOUGH_DATA
        ) {
          lastDecodeAt = now;
          canvas.width = video.videoWidth;
          canvas.height = video.videoHeight;
          ctx.drawImage(video, 0, 0, canvas.width, canvas.height);

          const image = ctx.getImageData(0, 0, canvas.width, canvas.height);

          decoding = true;
          decodeImageData(image, session, scanGeneration, onDecode)
            .then(() => {
              decodeFailures = 0;
            })
            .catch(() => {
              if (session !== activeScan) {
                return;
              }

              decodeFailures += 1;

              if (decodeFailures < DECODE_FAILURE_LIMIT) {
                return;
              }

              stop();
              onError(Error$ScannerUnavailable());
            })
            .finally(() => {
              decoding = false;
            });
        }

        session.frameId = requestAnimationFrame(tick);
      };

      session.frameId = requestAnimationFrame(tick);
    })
    .catch((err) => {
      if (session !== activeScan) {
        return;
      }

      stop();
      onError(scanError(err));
    });

  return undefined;
}

export function stop() {
  const session = activeScan;
  activeScan = null;

  if (session === null) {
    return undefined;
  }

  if (session.frameId !== null) {
    cancelAnimationFrame(session.frameId);
  }

  if (session.stream) {
    for (const track of session.stream.getTracks()) {
      track.stop();
    }
  }

  session.video.srcObject = null;
  session.video.remove();

  return undefined;
}
