const crypto = require("crypto");

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SECRET_KEY = process.env.SUPABASE_SECRET_KEY;
const JWT_SECRET = process.env.JWT_SECRET;

function send(res, status, data) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json; charset=utf-8");
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
      (err, derivedKey) => {
        if (err) return reject(err);

        resolve(
          salt + ":" + derivedKey.toString("hex")
        );
      }
    );
  });
}

function verifyPassword(password, stored) {
  return new Promise((resolve, reject) => {
    const parts = String(stored).split(":");

    if (parts.length !== 2) {
      return resolve(false);
    }

    const salt = parts[0];
    const original = Buffer.from(parts[1], "hex");

    crypto.pbkdf2(
      password,
      salt,
      100000,
      64,
      "sha512",
      (err, derivedKey) => {
        if (err) return reject(err);

        const current = derivedKey;

        if (current.length !== original.length) {
          return resolve(false);
        }

        resolve(
          crypto.timingSafeEqual(current, original)
        );
      }
    );
  });
}

function base64url(value) {
  return Buffer.from(value)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=/g, "");
}

function createToken(player) {
  const header = base64url(
    JSON.stringify({
      alg: "HS256",
      typ: "JWT"
    })
  );

  const payload = base64url(
    JSON.stringify({
      id: player.id,
      username: player.username,
      email: player.email,
      iat: Math.floor(Date.now() / 1000)
    })
  );

  const data = header + "." + payload;

  const signature = crypto
    .createHmac("sha256", JWT_SECRET)
    .update(data)
    .digest();

  return data + "." + base64url(signature);
}
function verifyToken(token) {
  try {
    const parts = String(token || "").split(".");

    if (parts.length !== 3) {
      return null;
    }

    const [header, payload, signature] = parts;

    const data = header + "." + payload;

    const expectedSignature = crypto
      .createHmac("sha256", JWT_SECRET)
      .update(data)
      .digest();

    const actualSignature = Buffer.from(
      signature
        .replace(/-/g, "+")
        .replace(/_/g, "/"),
      "base64"
    );

    if (expectedSignature.length !== actualSignature.length) {
      return null;
    }

    if (
      !crypto.timingSafeEqual(
        expectedSignature,
        actualSignature
      )
    ) {
      return null;
    }

    const decoded = JSON.parse(
      Buffer.from(
        payload
          .replace(/-/g, "+")
          .replace(/_/g, "/"),
        "base64"
      ).toString("utf8")
    );

    return decoded;
  } catch (error) {
    return null;
  }
}
async function supabase(path, options = {}) {
  const response = await fetch(
    SUPABASE_URL + "/rest/v1/" + path,
    {
      ...options,
      headers: {
        apikey: SUPABASE_SECRET_KEY,
        Authorization: "Bearer " + SUPABASE_SECRET_KEY,
        "Content-Type": "application/json",
        ...(options.headers || {})
      }
    }
  );

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
    return send(res, 400, {
      success: false,
      message: "Tüm alanları doldurun."
    });
  }

  if (username.length < 3) {
    return send(res, 400, {
      success: false,
      message: "Kullanıcı adı en az 3 karakter olmalı."
    });
  }

  if (password.length < 6) {
    return send(res, 400, {
      success: false,
      message: "Şifre en az 6 karakter olmalı."
    });
  }

  const existingEmail = await supabase(
    "players?select=id&email=eq." +
      encodeURIComponent(email) +
      "&limit=1"
  );

  if (!existingEmail.ok) {
    console.error("Email kontrol hatası:", existingEmail.data);

    return send(res, 500, {
      success: false,
      message: "Veritabanına bağlanılamadı."
    });
  }

  if (existingEmail.data.length > 0) {
    return send(res, 409, {
      success: false,
      message: "Bu e-posta zaten kayıtlı."
    });
  }

  const existingUsername = await supabase(
    "players?select=id&username=eq." +
      encodeURIComponent(username) +
      "&limit=1"
  );

  if (!existingUsername.ok) {
    console.error(
      "Username kontrol hatası:",
      existingUsername.data
    );

    return send(res, 500, {
      success: false,
      message: "Veritabanına bağlanılamadı."
    });
  }

  if (existingUsername.data.length > 0) {
    return send(res, 409, {
      success: false,
      message: "Bu kullanıcı adı zaten kullanılıyor."
    });
  }

  const passwordHash = await hashPassword(password);

  const playerResult = await supabase("players", {
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
    console.error(
      "Oyuncu oluşturma hatası:",
      playerResult.data
    );

    return send(res, 500, {
      success: false,
      message: "Oyuncu oluşturulamadı."
    });
  }

  const player = playerResult.data[0];

  const cityResult = await supabase("cities", {
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
    console.error(
      "Şehir oluşturma hatası:",
      cityResult.data
    );

    return send(res, 500, {
      success: false,
      message: "Başlangıç kolonisi oluşturulamadı."
    });
  }

  const token = createToken(player);

  return send(res, 201, {
    success: true,
    message: "Hesabın başarıyla oluşturuldu.",
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
    return send(res, 400, {
      success: false,
      message: "E-posta ve şifre gerekli."
    });
  }

  const result = await supabase(
    "players?select=id,username,email,password_hash&email=eq." +
      encodeURIComponent(email) +
      "&limit=1"
  );

  if (!result.ok) {
    console.error("Login DB hatası:", result.data);

    return send(res, 500, {
      success: false,
      message: "Veritabanına bağlanılamadı."
    });
  }

  if (!result.data || result.data.length === 0) {
    return send(res, 401, {
      success: false,
      message: "E-posta veya şifre hatalı."
    });
  }

  const player = result.data[0];

  const valid = await verifyPassword(
    password,
    player.password_hash
  );

  if (!valid) {
    return send(res, 401, {
      success: false,
      message: "E-posta veya şifre hatalı."
    });
  }

  const token = createToken(player);

  return send(res, 200, {
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
async function getCity(req, res) {
  const authHeader = String(
    req.headers.authorization || ""
  );

  if (!authHeader.startsWith("Bearer ")) {
    return send(res, 401, {
      success: false,
      message: "Oturum bulunamadı."
    });
  }

  const token = authHeader.slice(7).trim();
  const decoded = verifyToken(token);

  if (!decoded || !decoded.id) {
    return send(res, 401, {
      success: false,
      message: "Geçersiz oturum."
    });
  }

  const playerId = Number(decoded.id);

  if (!Number.isInteger(playerId)) {
    return send(res, 401, {
      success: false,
      message: "Geçersiz oyuncu."
    });
  }

  const result = await supabase(
    "cities?select=*&player_id=eq." +
      encodeURIComponent(playerId) +
      "&limit=1"
  );

  if (!result.ok) {
    console.error("City DB hatası:", result.data);

    return send(res, 500, {
      success: false,
      message: "Koloni veritabanından alınamadı."
    });
  }

  if (result.data && result.data.length > 0) {
    return send(res, 200, {
      success: true,
      city: result.data[0]
    });
  }

  const createResult = await supabase(
    "cities",
    {
      method: "POST",
      headers: {
        Prefer: "return=representation"
      },
      body: JSON.stringify({
        player_id: playerId,
        name: "Yeni Koloni",
        level: 1,
        metal: 1000,
        energy: 500,
        water: 500,
        crystal: 250
      })
    }
  );

  if (!createResult.ok) {
    console.error(
      "City oluşturma hatası:",
      createResult.data
    );

    return send(res, 500, {
      success: false,
      message: "Koloni oluşturulamadı."
    });
  }

  return send(res, 200, {
    success: true,
    city: createResult.data[0]
  });
}
module.exports = async function handler(req, res) {
  try {
    if (
      !SUPABASE_URL ||
      !SUPABASE_SECRET_KEY ||
      !JWT_SECRET
    ) {
      return send(res, 500, {
        success: false,
        message: "Sunucu yapılandırması eksik."
      });
    }

    if (req.method !== "POST") {
      return send(res, 405, {
        success: false,
        message: "Sadece POST isteği kabul edilir."
      });
    }

    const action = String(
      req.query.action || ""
    ).toLowerCase();

    if (action === "register") {
      return await register(req, res);
    }

    if (action === "login") {
      return await login(req, res);
    }
    if (action === "city") {
  return await getCity(req, res);
}

    return send(res, 400, {
      success: false,
      message: "Geçersiz işlem."
    });

  } catch (error) {
    console.error("NEXORA AUTH ERROR:", error);

    return send(res, 500, {
      success: false,
      message: "Sunucu hatası oluştu."
    });
  }
};
