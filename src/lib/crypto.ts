/**
 * On-device client-side cryptography using standard Web Crypto API (AES-GCM).
 * This ensures no keys, passcodes, or raw emotional reflections ever touch any cloud server.
 */

function bufToHex(buffer: ArrayBuffer): string {
  const byteArray = new Uint8Array(buffer);
  return Array.from(byteArray)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function hexToBuf(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

async function deriveKey(password: string, salt: Uint8Array): Promise<CryptoKey> {
  const encoder = new TextEncoder();
  const passwordBuffer = encoder.encode(password);

  const importedKey = await window.crypto.subtle.importKey(
    "raw",
    passwordBuffer,
    { name: "PBKDF2" },
    false,
    ["deriveKey"]
  );

  return window.crypto.subtle.deriveKey(
    {
      name: "PBKDF2",
      salt: salt as any,
      iterations: 10000,
      hash: "SHA-256",
    },
    importedKey,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"]
  );
}

/**
 * Encrypt plaintext using a user-specified passcode.
 * Outputs: saltHex:ivHex:ciphertextHex
 */
export async function encryptText(text: string, passcode: string): Promise<string> {
  try {
    const encoder = new TextEncoder();
    const data = encoder.encode(text);

    const salt = window.crypto.getRandomValues(new Uint8Array(16));
    const iv = window.crypto.getRandomValues(new Uint8Array(12));

    const key = await deriveKey(passcode, salt);

    const ciphertext = await window.crypto.subtle.encrypt(
      {
        name: "AES-GCM",
        iv: iv as any,
      },
      key,
      data
    );

    const saltHex = bufToHex(salt.buffer as ArrayBuffer);
    const ivHex = bufToHex(iv.buffer as ArrayBuffer);
    const cipherHex = bufToHex(ciphertext);

    return `${saltHex}:${ivHex}:${cipherHex}`;
  } catch (err) {
    console.error("Encryption failed:", err);
    throw new Error("On-device encryption failed. Please ensure Web Crypto is supported.");
  }
}

/**
 * Decrypt cipher text using the correct passcode.
 */
export async function decryptText(encryptedHex: string, passcode: string): Promise<string> {
  try {
    const parts = encryptedHex.split(":");
    if (parts.length !== 3) {
      throw new Error("Invalid encrypted data format.");
    }

    const salt = hexToBuf(parts[0]);
    const iv = hexToBuf(parts[1]);
    const ciphertext = hexToBuf(parts[2]);

    const key = await deriveKey(passcode, salt);

    const decryptedBuffer = await window.crypto.subtle.decrypt(
      {
        name: "AES-GCM",
        iv: iv as any,
      },
      key,
      ciphertext as any
    );

    const decoder = new TextDecoder();
    return decoder.decode(decryptedBuffer);
  } catch (err) {
    console.error("Decryption failed:", err);
    throw new Error("Decryption failed. Incorrect passcode or corrupted entry.");
  }
}

/**
 * Create a secure SHA-256 hash of the passcode for fast offline validation.
 */
export async function hashPasscode(passcode: string): Promise<string> {
  try {
    const encoder = new TextEncoder();
    const data = encoder.encode(passcode + "wellness-secure-salt-2026");
    const hashBuffer = await window.crypto.subtle.digest("SHA-256", data);
    return bufToHex(hashBuffer);
  } catch (err) {
    console.error("Hashing failed, falling back to simple hash:", err);
    // Simple fallback if subtle digest fails in sandboxed iframes without secure contexts
    let hash = 0;
    const salted = passcode + "wellness-secure-salt-2026";
    for (let i = 0; i < salted.length; i++) {
      hash = (hash << 5) - hash + salted.charCodeAt(i);
      hash |= 0;
    }
    return "fallback-hash-" + Math.abs(hash).toString(16);
  }
}
