import crypto from "crypto";

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SECRET_KEY = process.env.SUPABASE_SECRET_KEY;
const JWT_SECRET = process.env.JWT_SECRET;

function json(res, status, data) {
  res.status(status).setHeader("Content-Type", "application/json");
  res.end(JSON.stringify(data));
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";

    req.on("data", chunk => {
      body += chunk;
    });

    req.on("end", () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch {
        reject(new Error("Geçersiz JSON"));
      }
    });

    req.on("error", reject);
  });
}

function hashPassword(password) {
  return new Promise((resolve, reject) => {
    const salt = crypto.randomBytes(16).toString("hex");

    crypto.pbkdf2(
      password,
      salt,
      100000,
      64,
      "sha512",
      (error, derivedKey) => {
        if (error) {
          reject(error);
          return;
        }

        resolve(`${salt}:${derivedKey.toString("hex")}`);
      }
    );
  });
}

function verifyPassword(password, storedHash) {
  return new Promise((resolve, reject) => {
    const parts = storedHash.split(":");

    if (parts.length !== 2) {
      resolve(false);
      return;
    }

    const salt = parts[0];
    const originalHash = parts[1];

    crypto.pbkdf2(
      password,
      salt,
      100000,
      64,
      "sha512",
      (error, derivedKey) => {
        if (error) {
          reject(error);
          return;
        }

        const newHash = derivedKey.toString("hex");

        const a = Buffer.from(newHash, "hex");
        const b = Buffer.from(originalHash, "hex");

        if (a.length !== b.length) {
          resolve(false);
          return;
        }

        resolve(crypto.timingSafeEqual(a, b));
      }
    );
  });
}

function base64url(input) {
  return Buffer.from(input)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=/g, "");
}

function createJWT(payload) {
  const header = {
    alg: "HS256",
    typ: "JWT"
  };

  const encodedHeader = base64url(JSON.stringify(header));
  const encodedPayload = base64url(JSON.stringify(payload));

  const data = `${encodedHeader}.${encodedPayload}`;

  const signature = crypto
    .createHmac("sha256", JWT_SECRET)
    .update(data)
    .digest();

  return `${data}.${base64url(signature)}`;
}

async function supabaseRequest(path, options = {}) {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...options,
    headers: {
      apikey: SUPABASE_SECRET_KEY,
      Authorization: `Bearer ${SUPABASE_SECRET_KEY}`,
      "Content-Type": "application/json",
      ...(options.headers || {})
    }
  });

  const text = await response.text();

  let data = null;

  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = text;
  }

  return {
    ok: response.ok,
    status: response.status,
    data
  };
}

async function register(req, res) {
  const body = await readBody(req);

  const username = String(body.username || "").trim();
  const email = String(body.email || "").trim().toLowerCase();
  const password = String(body.password || "");

  if (!username || !email || !password) {
    return json(res, 400, {
      success: false,
      message: "Kullanıcı adı, e-posta ve şifre zorunludur."
    });
  }

  if (username.length < 3) {
    return json(res, 400, {
      success: false,
      message: "Kullanıcı adı en az 3 karakter olmalıdır."
    });
  }

  if (password.length < 6) {
    return json(res, 400, {
      success: false,
      message: "Şifre en az 6 karakter olmalıdır."
    });
  }

  const emailCheck = await supabaseRequest(
    `players?select=id&email=eq.${encodeURIComponent(email)}&limit=1`
  );

  if (!emailCheck.ok) {
    return json(res, 500, {
      success: false,
      message: "Veritabanı kontrolü başarısız."
    });
  }

  if (emailCheck.data && emailCheck.data.length > 0) {
    return json(res, 409, {
      success: false,
      message: "Bu e-posta adresi zaten kayıtlı."
    });
  }

  const usernameCheck = await supabaseRequest(
    `players?select=id&username=eq.${encodeURIComponent(username)}&limit=1`
  );

  if (!usernameCheck.ok) {
    return json(res, 500, {
      success: false,
      message: "Veritabanı kontrolü başarısız."
    });
  }

  if (usernameCheck.data && usernameCheck.data.length > 0) {
    return json(res, 409, {
      success: false,
      message: "Bu kullanıcı adı zaten kullanılıyor."
    });
  }

  const passwordHash = await hashPassword(password);

  const playerResult = await supabaseRequest("players", {
    method: "POST",
    headers: {
      Prefer: "return=representation"
    },
    body: JSON.stringify({
      username,
      email,
      password_hash: passwordHash
    })
  });

  if (!playerResult.ok) {
    return json(res, 500, {
      success: false,
      message: "Oyuncu oluşturulamadı."
    });
  }

  const player = Array.isArray(playerResult.data)
    ? playerResult.data[0]
    : playerResult.data;

  if (!player || !player.id) {
    return json(res, 500, {
      success: false,
      message: "Oyuncu oluşturuldu ancak oyuncu bilgisi alınamadı."
    });
  }

  const cityResult = await supabaseRequest("cities", {
    method: "POST",
    headers: {
      Prefer: "return=minimal"
    },
    body: JSON.stringify({
      player_id: player.id,
      name: "Yeni Koloni",
      level: 1,
      metal: 1000,
      energy: 500,
      water: 500,
      crystal: 250
    })
  });

  if (!cityResult.ok) {
    return json(res, 500, {
      success: false,
      message: "Oyuncu oluşturuldu fakat başlangıç kolonisi oluşturulamadı."
    });
  }

  const token = createJWT({
    id: player.id,
    username: player.username,
    email: player.email,
    iat: Math.floor(Date.now() / 1000)
  });

  return json(res, 201, {
    success: true,
    message: "NEXORA hesabın başarıyla oluşturuldu.",
    token,
    player: {
      id: player.id,
      username: player.username,
      email: player.email
    }
  });
}

async function login(req, res) {
  const body = await readBody(req);

  const email = String(body.email || "").trim().toLowerCase();
  const password = String(body.password || "");

  if (!email || !password) {
    return json(res, 400, {
      success: false,
      message: "E-posta ve şifre zorunludur."
    });
  }

  const result = await supabaseRequest(
    `players?select=id,username,email,password_hash&email=eq.${encodeURIComponent(email)}&limit=1`
  );

  if (!result.ok) {
    return json(res, 500, {
      success: false,
      message: "Giriş sırasında veritabanı hatası oluştu."
    });
  }

  if (!result.data || result.data.length === 0) {
    return json(res, 401, {
      success: false,
      message: "E-posta veya şifre hatalı."
    });
  }

  const player = result.data[0];

  const validPassword = await verifyPassword(
    password,
    player.password_hash
  );

  if (!validPassword) {
    return json(res, 401, {
      success: false,
      message: "E-posta veya şifre hatalı."
    });
  }

  const token = createJWT({
    id: player.id,
    username: player.username,
    email: player.email,
    iat: Math.floor(Date.now() / 1000)
  });

  return json(res, 200, {
    success: true,
    message: "Giriş başarılı.",
    token,
    player: {
      id: player.id,
      username: player.username,
      email: player.email
    }
  });
}

export default async function handler(req, res) {
  try {
    if (!SUPABASE_URL || !SUPABASE_SECRET_KEY || !JWT_SECRET) {
      return json(res, 500, {
        success: false,
        message: "Sunucu yapılandırması eksik."
      });
    }

    if (req.method !== "POST") {
      return json(res, 405, {
        success: false,
        message: "Sadece POST isteği kabul edilir."
      });
    }

    const action = String(req.query.action || "").toLowerCase();

    if (action === "register") {
      return await register(req, res);
    }

    if (action === "login") {
      return await login(req, res);
    }

    return json(res, 400, {
      success: false,
      message: "Geçersiz işlem. register veya login kullanın."
    });
  } catch (error) {
    console.error("NEXORA AUTH ERROR:", error);

    return json(res, 500, {
      success: false,
      message: "Sunucu hatası oluştu."
    });
  }
}
