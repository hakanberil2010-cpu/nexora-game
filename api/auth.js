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
    let city = result.data[0];

    const buildingsResult = await supabase(
      "buildings?select=*&city_id=eq." +
        encodeURIComponent(city.id)
    );

    if (!buildingsResult.ok) {
      return send(res, 500, {
        success: false,
        message: "Bina verileri alınamadı."
      });
    }

    const buildings = buildingsResult.data || [];

    const unitsResult = await supabase(
      "units?select=*&city_id=eq." +
        encodeURIComponent(city.id)
    );

    if (!unitsResult.ok) {
      return send(res, 500, {
        success: false,
        message: "Ordu verileri alınamadı."
      });
    }

    const units = unitsResult.data || [];

    function getBuildingLevel(name) {
      const building = buildings.find(function(item) {
        return item.building_type === name;
      });

      return building ? Number(building.level) : 0;
    }

    const metalLevel = getBuildingLevel("Metal Madeni");
    const energyLevel = getBuildingLevel("Enerji Santrali");
    const waterLevel = getBuildingLevel("Su Arıtma");

    const now = Date.now();
    const lastProduction = new Date(
      city.last_production_at
    ).getTime();

    const elapsedMinutes = Math.floor(
      (now - lastProduction) / 60000
    );

    if (elapsedMinutes > 0) {
      const metalGain = metalLevel * 10 * elapsedMinutes;
      const energyGain = energyLevel * 10 * elapsedMinutes;
      const waterGain = waterLevel * 10 * elapsedMinutes;
      const crystalGain = 2 * elapsedMinutes;

      const updatedCityResult = await supabase(
        "cities?id=eq." +
          encodeURIComponent(city.id),
        {
          method: "PATCH",
          headers: {
            Prefer: "return=representation"
          },
          body: JSON.stringify({
            metal: city.metal + metalGain,
            energy: city.energy + energyGain,
            water: city.water + waterGain,
            crystal: city.crystal + crystalGain,
            last_production_at: new Date().toISOString()
          })
        }
      );

      if (!updatedCityResult.ok) {
        return send(res, 500, {
          success: false,
          message: "Kaynak üretimi kaydedilemedi."
        });
      }

      city = updatedCityResult.data[0];
    }

    return send(res, 200, {
      success: true,
      city: city,
      buildings: buildingsResult.data || [],
      units: units
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

async function produceArmy(req, res) {
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

  const body = await readBody(req);
  const unitType = String(body.unitType || "").trim();

  const armyCosts = {
    piyade: {
      metal: 100,
      energy: 20
    },
    savunma: {
      metal: 150,
      energy: 40
    },
    saldiri: {
      metal: 200,
      energy: 75
    }
  };

  const cost = armyCosts[unitType];

  if (!cost) {
    return send(res, 400, {
      success: false,
      message: "Geçersiz birlik türü."
    });
  }

  const cityResult = await supabase(
    "cities?select=*&player_id=eq." +
      encodeURIComponent(decoded.id) +
      "&limit=1"
  );

  if (!cityResult.ok || !cityResult.data || !cityResult.data[0]) {
    return send(res, 404, {
      success: false,
      message: "Koloni bulunamadı."
    });
  }

  const city = cityResult.data[0];

  if (
    Number(city.metal) < cost.metal ||
    Number(city.energy) < cost.energy
  ) {
    return send(res, 400, {
      success: false,
      message: "Yeterli kaynak yok."
    });
  }

  const newMetal = Number(city.metal) - cost.metal;
  const newEnergy = Number(city.energy) - cost.energy;

  const updatedCityResult = await supabase(
    "cities?id=eq." + encodeURIComponent(city.id),
    {
      method: "PATCH",
      headers: {
        Prefer: "return=representation"
      },
      body: JSON.stringify({
        metal: newMetal,
        energy: newEnergy
      })
    }
  );

  if (!updatedCityResult.ok) {
    return send(res, 500, {
      success: false,
      message: "Kaynaklar güncellenemedi."
    });
  }

  const unitsResult = await supabase(
    "units?select=*&city_id=eq." +
      encodeURIComponent(city.id) +
      "&unit_type=eq." +
      encodeURIComponent(unitType) +
      "&limit=1"
  );

  if (!unitsResult.ok) {
    return send(res, 500, {
      success: false,
      message: "Ordu verisi alınamadı."
    });
  }

  let unit;

  if (unitsResult.data && unitsResult.data[0]) {
    unit = unitsResult.data[0];

    const updatedUnitResult = await supabase(
      "units?id=eq." + encodeURIComponent(unit.id),
      {
        method: "PATCH",
        headers: {
          Prefer: "return=representation"
        },
        body: JSON.stringify({
          quantity: Number(unit.quantity) + 1
        })
      }
    );

    if (!updatedUnitResult.ok) {
      return send(res, 500, {
        success: false,
        message: "Birlik üretilemedi."
      });
    }

    unit = updatedUnitResult.data[0];
  } else {
    const createUnitResult = await supabase(
      "units",
      {
        method: "POST",
        headers: {
          Prefer: "return=representation"
        },
        body: JSON.stringify({
          city_id: city.id,
          unit_type: unitType,
          quantity: 1
        })
      }
    );

    if (!createUnitResult.ok) {
      return send(res, 500, {
        success: false,
        message: "Birlik oluşturulamadı."
      });
    }

    unit = createUnitResult.data[0];
  }

  return send(res, 200, {
    success: true,
    message: "Birlik üretildi.",
    city: updatedCityResult.data[0],
    unit: unit
  });
}

async function attackPlayer(req, res) {
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

  const body = await readBody(req);
  const targetPlayerId = Number(body.targetPlayerId);

  if (!Number.isInteger(targetPlayerId)) {
    return send(res, 400, {
      success: false,
      message: "Geçersiz hedef oyuncu."
    });
  }

  if (targetPlayerId === Number(decoded.id)) {
    return send(res, 400, {
      success: false,
      message: "Kendi kolonine saldıramazsın."
    });
  }

  const attackerCityResult = await supabase(
    "cities?select=*&player_id=eq." +
      encodeURIComponent(decoded.id) +
      "&limit=1"
  );

  if (
    !attackerCityResult.ok ||
    !attackerCityResult.data ||
    !attackerCityResult.data[0]
  ) {
    return send(res, 404, {
      success: false,
      message: "Saldıran koloninin verisi bulunamadı."
    });
  }

  const targetCityResult = await supabase(
    "cities?select=*&player_id=eq." +
      encodeURIComponent(targetPlayerId) +
      "&limit=1"
  );

  if (
    !targetCityResult.ok ||
    !targetCityResult.data ||
    !targetCityResult.data[0]
  ) {
    return send(res, 404, {
      success: false,
      message: "Hedef koloni bulunamadı."
    });
  }

  const attackerCity = attackerCityResult.data[0];
  const targetCity = targetCityResult.data[0];

  const attackerUnitsResult = await supabase(
    "units?select=*&city_id=eq." +
      encodeURIComponent(attackerCity.id)
  );

  if (!attackerUnitsResult.ok) {
    return send(res, 500, {
      success: false,
      message: "Saldırı ordusu alınamadı."
    });
  }

  const targetUnitsResult = await supabase(
    "units?select=*&city_id=eq." +
      encodeURIComponent(targetCity.id)
  );

  if (!targetUnitsResult.ok) {
    return send(res, 500, {
      success: false,
      message: "Hedef savunması alınamadı."
    });
  }

  const attackerUnits = attackerUnitsResult.data || [];
  const targetUnits = targetUnitsResult.data || [];

  function getUnit(units, type) {
    return units.find(function(item) {
      return item.unit_type === type;
    });
  }

  function getUnitCount(units, type) {
    const unit = getUnit(units, type);
    return unit ? Number(unit.quantity) : 0;
  }

  function calculateLoss(quantity, percent) {
    if (quantity <= 0) {
      return 0;
    }

    const loss = Math.ceil(quantity * percent);

    return Math.min(quantity, Math.max(1, loss));
  }

  const infantry = getUnitCount(
    attackerUnits,
    "piyade"
  );

  const attackUnits = getUnitCount(
    attackerUnits,
    "saldiri"
  );

  const defenseUnits = getUnitCount(
    targetUnits,
    "savunma"
  );

  const attackerResearchResult = await supabase(
    "research?select=combat_level&player_id=eq." +
      encodeURIComponent(decoded.id) +
      "&limit=1"
  );

  const defenderResearchResult = await supabase(
    "research?select=defense_level&player_id=eq." +
      encodeURIComponent(targetPlayerId) +
      "&limit=1"
  );

  if (
    !attackerResearchResult.ok ||
    !defenderResearchResult.ok
  ) {
    return send(res, 500, {
      success: false,
      message: "Araştırma seviyeleri alınamadı."
    });
  }

  const attackerCombatLevel =
    attackerResearchResult.data &&
    attackerResearchResult.data[0]
      ? Number(
          attackerResearchResult.data[0].combat_level || 0
        )
      : 0;

  const defenderDefenseLevel =
    defenderResearchResult.data &&
    defenderResearchResult.data[0]
      ? Number(
          defenderResearchResult.data[0].defense_level || 0
        )
      : 0;

  const attackMultiplier =
    1 + attackerCombatLevel * 0.10;

  const defenseMultiplier =
    1 + defenderDefenseLevel * 0.10;

  const totalAttackPower = Math.round(
    (
      infantry * 1 +
      attackUnits * 3
    ) * attackMultiplier
  );

  const totalDefensePower = Math.round(
    defenseUnits * 2 * defenseMultiplier
  );

  if (totalAttackPower <= 0) {
    return send(res, 400, {
      success: false,
      message: "Saldırı için yeterli asker yok."
    });
  }

  let result;
  let lootPercent = 0;

  let attackerLossPercent = 0;
  let defenderLossPercent = 0;

  if (totalAttackPower > totalDefensePower) {
    result = "Zafer";
    lootPercent = 0.10;

    attackerLossPercent = 0.20;
    defenderLossPercent = 0.60;

  } else if (totalAttackPower === totalDefensePower) {
    result = "Beraberlik";

    attackerLossPercent = 0.40;
    defenderLossPercent = 0.40;

  } else {
    result = "Yenilgi";

    attackerLossPercent = 0.70;
    defenderLossPercent = 0.20;
  }

  const infantryLoss = calculateLoss(
    infantry,
    attackerLossPercent
  );

  const attackUnitsLoss = calculateLoss(
    attackUnits,
    attackerLossPercent
  );

  const defenseLoss = calculateLoss(
    defenseUnits,
    defenderLossPercent
  );

  async function updateUnitLoss(units, type, loss) {
    if (loss <= 0) {
      return true;
    }

    const unit = getUnit(units, type);

    if (!unit) {
      return true;
    }

    const newQuantity = Math.max(
      0,
      Number(unit.quantity) - loss
    );

    const updateResult = await supabase(
      "units?id=eq." +
        encodeURIComponent(unit.id),
      {
        method: "PATCH",
        headers: {
          Prefer: "return=minimal"
        },
        body: JSON.stringify({
          quantity: newQuantity
        })
      }
    );

    return updateResult.ok;
  }

  const attackerInfantryUpdated =
    await updateUnitLoss(
      attackerUnits,
      "piyade",
      infantryLoss
    );

  if (!attackerInfantryUpdated) {
    return send(res, 500, {
      success: false,
      message: "Piyade kaybı kaydedilemedi."
    });
  }

  const attackerUnitsUpdated =
    await updateUnitLoss(
      attackerUnits,
      "saldiri",
      attackUnitsLoss
    );

  if (!attackerUnitsUpdated) {
    return send(res, 500, {
      success: false,
      message: "Saldırı birliği kaybı kaydedilemedi."
    });
  }

  const defenderUpdated =
    await updateUnitLoss(
      targetUnits,
      "savunma",
      defenseLoss
    );

  if (!defenderUpdated) {
    return send(res, 500, {
      success: false,
      message: "Savunma kaybı kaydedilemedi."
    });
  }

  const metalLoot =
    Math.floor(
      Number(targetCity.metal) * lootPercent
    );

  const energyLoot =
    Math.floor(
      Number(targetCity.energy) * lootPercent
    );

  const waterLoot =
    Math.floor(
      Number(targetCity.water) * lootPercent
    );

  const crystalLoot =
    Math.floor(
      Number(targetCity.crystal) * lootPercent
    );

  if (result === "Zafer" && lootPercent > 0) {
    const targetUpdate = await supabase(
      "cities?id=eq." +
        encodeURIComponent(targetCity.id),
      {
        method: "PATCH",
        headers: {
          Prefer: "return=representation"
        },
        body: JSON.stringify({
          metal: Math.max(
            0,
            Number(targetCity.metal) - metalLoot
          ),
          energy: Math.max(
            0,
            Number(targetCity.energy) - energyLoot
          ),
          water: Math.max(
            0,
            Number(targetCity.water) - waterLoot
          ),
          crystal: Math.max(
            0,
            Number(targetCity.crystal) - crystalLoot
          )
        })
      }
    );

    if (!targetUpdate.ok) {
      return send(res, 500, {
        success: false,
        message: "Ganimet kaydedilemedi."
      });
    }

    const attackerUpdate = await supabase(
      "cities?id=eq." +
        encodeURIComponent(attackerCity.id),
      {
        method: "PATCH",
        headers: {
          Prefer: "return=representation"
        },
        body: JSON.stringify({
          metal:
            Number(attackerCity.metal) +
            metalLoot,
          energy:
            Number(attackerCity.energy) +
            energyLoot,
          water:
            Number(attackerCity.water) +
            waterLoot,
          crystal:
            Number(attackerCity.crystal) +
            crystalLoot
        })
      }
    );

    if (!attackerUpdate.ok) {
      return send(res, 500, {
        success: false,
        message:
          "Ganimet saldıran koloniye aktarılamadı."
      });
    }
  }

  const battleReportResult = await supabase(
    "battle_reports",
    {
      method: "POST",
      headers: {
        Prefer: "return=minimal"
      },
      body: JSON.stringify({
        attacker_player_id: Number(decoded.id),
        defender_player_id: targetPlayerId,
        result: result,
        attack_power: totalAttackPower,
        defense_power: totalDefensePower,
        attacker_losses: {
          piyade: infantryLoss,
          saldiri: attackUnitsLoss
        },
        defender_losses: {
          savunma: defenseLoss
        },
        loot: {
          metal: metalLoot,
          energy: energyLoot,
          water: waterLoot,
          crystal: crystalLoot
        }
      })
    }
  );

  if (!battleReportResult.ok) {
    console.error(
      "Savaş raporu kaydedilemedi:",
      battleReportResult.data
    );

    return send(res, 500, {
      success: false,
      message: "Savaş raporu kaydedilemedi."
    });
  }

  return send(res, 200, {
    success: true,
    result: result,
    attackPower: totalAttackPower,
    defensePower: totalDefensePower,
    losses: {
      attacker: {
        piyade: infantryLoss,
        saldiri: attackUnitsLoss
      },
      defender: {
        savunma: defenseLoss
      }
    },
    loot: {
      metal: metalLoot,
      energy: energyLoot,
      water: waterLoot,
      crystal: crystalLoot
    }
  });
}

async function upgradeResearch(req, res) {
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
  const body = await readBody(req);

  const researchType = String(
    body.researchType || ""
  ).trim();

  const researchMap = {
    production: "production_level",
    combat: "combat_level",
    defense: "defense_level",
    crystal: "crystal_level"
  };

  const column = researchMap[researchType];

  if (!column) {
    return send(res, 400, {
      success: false,
      message: "Geçersiz araştırma türü."
    });
  }

  const costs = {
    production: {
      metal: 500,
      energy: 150,
      crystal: 25
    },
    combat: {
      metal: 700,
      energy: 200,
      crystal: 40
    },
    defense: {
      metal: 600,
      energy: 180,
      crystal: 35
    },
    crystal: {
      metal: 800,
      energy: 250,
      crystal: 60
    }
  };

  const cost = costs[researchType];

  const cityResult = await supabase(
    "cities?select=*&player_id=eq." +
      encodeURIComponent(playerId) +
      "&limit=1"
  );

  if (
    !cityResult.ok ||
    !cityResult.data ||
    !cityResult.data[0]
  ) {
    return send(res, 404, {
      success: false,
      message: "Koloni bulunamadı."
    });
  }

  const city = cityResult.data[0];

  if (
    Number(city.metal) < cost.metal ||
    Number(city.energy) < cost.energy ||
    Number(city.crystal) < cost.crystal
  ) {
    return send(res, 400, {
      success: false,
      message: "Yeterli kaynak yok."
    });
  }

  const researchResult = await supabase(
    "research?select=*&player_id=eq." +
      encodeURIComponent(playerId) +
      "&limit=1"
  );

  if (!researchResult.ok) {
    return send(res, 500, {
      success: false,
      message: "Araştırma verisi alınamadı."
    });
  }

  let research;

  if (
    !researchResult.data ||
    researchResult.data.length === 0
  ) {
    const createResearch = await supabase(
      "research",
      {
        method: "POST",
        headers: {
          Prefer: "return=representation"
        },
        body: JSON.stringify({
          player_id: playerId
        })
      }
    );

    if (!createResearch.ok) {
      return send(res, 500, {
        success: false,
        message: "Araştırma kaydı oluşturulamadı."
      });
    }

    research = createResearch.data[0];
  } else {
    research = researchResult.data[0];
  }

  const currentLevel =
    Number(research[column] || 0);

  const newLevel = currentLevel + 1;

  const updateCity = await supabase(
    "cities?id=eq." +
      encodeURIComponent(city.id),
    {
      method: "PATCH",
      headers: {
        Prefer: "return=representation"
      },
      body: JSON.stringify({
        metal:
          Number(city.metal) - cost.metal,
        energy:
          Number(city.energy) - cost.energy,
        crystal:
          Number(city.crystal) - cost.crystal
      })
    }
  );

  if (!updateCity.ok) {
    return send(res, 500, {
      success: false,
      message: "Kaynaklar güncellenemedi."
    });
  }

  const updateResearch = await supabase(
    "research?id=eq." +
      encodeURIComponent(research.id),
    {
      method: "PATCH",
      headers: {
        Prefer: "return=representation"
      },
      body: JSON.stringify({
        [column]: newLevel
      })
    }
  );

  if (!updateResearch.ok) {
    return send(res, 500, {
      success: false,
      message: "Araştırma seviyesi güncellenemedi."
    });
  }

  return send(res, 200, {
    success: true,
    message: "Araştırma tamamlandı.",
    research: updateResearch.data[0],
    city: updateCity.data[0]
  });
}

async function createAlliance(req, res) {
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
  const body = await readBody(req);

  const name = String(body.name || "").trim();
  const tag = String(body.tag || "").trim().toUpperCase();

  if (!name || !tag) {
    return send(res, 400, {
      success: false,
      message: "İttifak adı ve etiketi gerekli."
    });
  }

  if (name.length < 3 || name.length > 30) {
    return send(res, 400, {
      success: false,
      message: "İttifak adı 3-30 karakter arasında olmalı."
    });
  }

  if (tag.length < 2 || tag.length > 5) {
    return send(res, 400, {
      success: false,
      message: "İttifak etiketi 2-5 karakter arasında olmalı."
    });
  }

  const existingMembership = await supabase(
    "alliance_members?select=id&player_id=eq." +
      encodeURIComponent(playerId) +
      "&limit=1"
  );

  if (!existingMembership.ok) {
    return send(res, 500, {
      success: false,
      message: "İttifak üyeliği kontrol edilemedi."
    });
  }

  if (
    existingMembership.data &&
    existingMembership.data.length > 0
  ) {
    return send(res, 400, {
      success: false,
      message: "Zaten bir ittifaka üyesin."
    });
  }

  const allianceResult = await supabase(
    "alliances",
    {
      method: "POST",
      headers: {
        Prefer: "return=representation"
      },
      body: JSON.stringify({
        name: name,
        tag: tag,
        owner_player_id: playerId
      })
    }
  );

  if (!allianceResult.ok) {
    return send(res, 400, {
      success: false,
      message:
        "İttifak oluşturulamadı. İsim veya etiket kullanılıyor olabilir."
    });
  }

  const alliance =
    allianceResult.data[0];

  const memberResult = await supabase(
    "alliance_members",
    {
      method: "POST",
      headers: {
        Prefer: "return=representation"
      },
      body: JSON.stringify({
        alliance_id: alliance.id,
        player_id: playerId,
        role: "leader"
      })
    }
  );

  if (!memberResult.ok) {
    await supabase(
      "alliances?id=eq." +
        encodeURIComponent(alliance.id),
      {
        method: "DELETE"
      }
    );

    return send(res, 500, {
      success: false,
      message: "İttifak üyeliği oluşturulamadı."
    });
  }

  return send(res, 201, {
    success: true,
    message: "İttifak başarıyla oluşturuldu.",
    alliance: alliance,
    member: memberResult.data[0]
  });
}

async function joinAlliance(req, res) {
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
  const body = await readBody(req);
  const allianceId = Number(body.allianceId);

  if (!Number.isInteger(allianceId)) {
    return send(res, 400, {
      success: false,
      message: "Geçersiz ittifak."
    });
  }

  const membershipResult = await supabase(
    "alliance_members?select=id,alliance_id,role" +
      "&player_id=eq." +
      encodeURIComponent(playerId) +
      "&limit=1"
  );

  if (!membershipResult.ok) {
    return send(res, 500, {
      success: false,
      message: "İttifak üyeliği kontrol edilemedi."
    });
  }

  if (
    membershipResult.data &&
    membershipResult.data.length > 0
  ) {
    return send(res, 400, {
      success: false,
      message: "Zaten bir ittifaka üyesin."
    });
  }

  const allianceResult = await supabase(
    "alliances?select=*&id=eq." +
      encodeURIComponent(allianceId) +
      "&limit=1"
  );

  if (
    !allianceResult.ok ||
    !allianceResult.data ||
    allianceResult.data.length === 0
  ) {
    return send(res, 404, {
      success: false,
      message: "İttifak bulunamadı."
    });
  }

  const memberResult = await supabase(
    "alliance_members",
    {
      method: "POST",
      headers: {
        Prefer: "return=representation"
      },
      body: JSON.stringify({
        alliance_id: allianceId,
        player_id: playerId,
        role: "member"
      })
    }
  );

  if (!memberResult.ok) {
    return send(res, 500, {
      success: false,
      message: "İttifaka katılım başarısız."
    });
  }

  return send(res, 201, {
    success: true,
    message: "İttifaka başarıyla katıldın.",
    alliance: allianceResult.data[0],
    member: memberResult.data[0]
  });
}
async function leaveAlliance(req, res) {
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

  const membershipResult = await supabase(
    "alliance_members?select=id,alliance_id,role&player_id=eq." +
      encodeURIComponent(playerId) +
      "&limit=1"
  );

  if (!membershipResult.ok) {
    return send(res, 500, {
      success: false,
      message: "İttifak üyeliği kontrol edilemedi."
    });
  }

  if (
    !membershipResult.data ||
    membershipResult.data.length === 0
  ) {
    return send(res, 400, {
      success: false,
      message: "Herhangi bir ittifaka üye değilsin."
    });
  }

  const membership = membershipResult.data[0];

  if (membership.role === "leader") {
    return send(res, 400, {
      success: false,
      message:
        "İttifak lideri doğrudan ayrılamaz. Önce liderliği devretmelisin."
    });
  }

  const deleteResult = await supabase(
    "alliance_members?id=eq." +
      encodeURIComponent(membership.id),
    {
      method: "DELETE"
    }
  );

  if (!deleteResult.ok) {
    return send(res, 500, {
      success: false,
      message: "İttifaktan ayrılma işlemi başarısız."
    });
  }

  return send(res, 200, {
    success: true,
    message: "İttifaktan başarıyla ayrıldın."
  });
}
async function getAlliances(req, res) {
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

  const result = await supabase(
    "alliances?select=id,name,tag,owner_player_id,created_at&order=name.asc"
  );

  if (!result.ok) {
    return send(res, 500, {
      success: false,
      message: "İttifaklar alınamadı."
    });
  }

  return send(res, 200, {
    success: true,
    alliances: result.data || []
  });
}

async function getResearch(req, res) {
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

  const result = await supabase(
    "research?select=*&player_id=eq." +
      encodeURIComponent(playerId) +
      "&limit=1"
  );

  if (!result.ok) {
    return send(res, 500, {
      success: false,
      message: "Araştırma verileri alınamadı."
    });
  }

  if (!result.data || result.data.length === 0) {
    const createResult = await supabase(
      "research",
      {
        method: "POST",
        headers: {
          Prefer: "return=representation"
        },
        body: JSON.stringify({
          player_id: playerId,
          production_level: 0,
          combat_level: 0,
          defense_level: 0,
          crystal_level: 0
        })
      }
    );

    if (!createResult.ok) {
      return send(res, 500, {
        success: false,
        message: "Araştırma kaydı oluşturulamadı."
      });
    }

    return send(res, 200, {
      success: true,
      research: createResult.data[0]
    });
  }

  return send(res, 200, {
    success: true,
    research: result.data[0]
  });
}

async function getBattleReports(req, res) {
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

  const reportsResult = await supabase(
    "battle_reports?select=*&or=(attacker_player_id.eq." +
      encodeURIComponent(playerId) +
      ",defender_player_id.eq." +
      encodeURIComponent(playerId) +
      ")&order=created_at.desc"
  );

  if (!reportsResult.ok) {
    console.error(
      "Savaş raporları alınamadı:",
      reportsResult.data
    );

    return send(res, 500, {
      success: false,
      message: "Savaş raporları alınamadı."
    });
  }

  const playersResult = await supabase(
    "players?select=id,username"
  );

  if (!playersResult.ok) {
    console.error(
      "Oyuncular alınamadı:",
      playersResult.data
    );

    return send(res, 500, {
      success: false,
      message: "Oyuncu bilgileri alınamadı."
    });
  }

  const players = playersResult.data || [];
  const playerMap = {};

  players.forEach(function(player) {
    playerMap[player.id] = player.username;
  });

  const reports = (reportsResult.data || []).map(
    function(report) {
      return {
        ...report,

        attacker_username:
          playerMap[report.attacker_player_id] ||
          "Bilinmeyen Oyuncu",

        defender_username:
          playerMap[report.defender_player_id] ||
          "Bilinmeyen Oyuncu"
      };
    }
  );

  return send(res, 200, {
    success: true,
    reports: reports
  });
}

async function upgradeBuilding(req, res) {
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

  const body = await readBody(req);
  const buildingType = String(body.building || "").trim();

  const costs = {
    "Metal Madeni": {
      metal: 500,
      energy: 100,
      water: 50,
      crystal: 25
    },

    "Enerji Santrali": {
      metal: 400,
      energy: 50,
      water: 50,
      crystal: 20
    },

    "Su Arıtma": {
      metal: 350,
      energy: 75,
      water: 50,
      crystal: 20
    },

    "Kışla": {
      metal: 450,
      energy: 100,
      water: 50,
      crystal: 25
    },

    "Merkez Bina": {
      metal: 750,
      energy: 150,
      water: 100,
      crystal: 50
    }
  };

  if (!costs[buildingType]) {
    return send(res, 400, {
      success: false,
      message: "Geçersiz bina."
    });
  }

  const cityResult = await supabase(
    "cities?select=*&player_id=eq." +
      encodeURIComponent(playerId) +
      "&limit=1"
  );

  if (
    !cityResult.ok ||
    !cityResult.data ||
    cityResult.data.length === 0
  ) {
    return send(res, 404, {
      success: false,
      message: "Koloni bulunamadı."
    });
  }

  const city = cityResult.data[0];
  const cost = costs[buildingType];

  if (
    city.metal < cost.metal ||
    city.energy < cost.energy ||
    city.water < cost.water ||
    city.crystal < cost.crystal
  ) {
    return send(res, 400, {
      success: false,
      message: "Yeterli kaynak bulunmuyor."
    });
  }

  const buildingResult = await supabase(
    "buildings?select=*&city_id=eq." +
      encodeURIComponent(city.id) +
      "&building_type=eq." +
      encodeURIComponent(buildingType) +
      "&limit=1"
  );

  if (!buildingResult.ok) {
    return send(res, 500, {
      success: false,
      message: "Bina verisi alınamadı."
    });
  }

  let building;

  if (
    buildingResult.data &&
    buildingResult.data.length > 0
  ) {
    building = buildingResult.data[0];

    const updateBuilding = await supabase(
      "buildings?id=eq." +
        encodeURIComponent(building.id),
      {
        method: "PATCH",
        headers: {
          Prefer: "return=representation"
        },
        body: JSON.stringify({
          level: Number(building.level) + 1
        })
      }
    );

    if (!updateBuilding.ok) {
      return send(res, 500, {
        success: false,
        message: "Bina geliştirilemedi."
      });
    }

    building = updateBuilding.data[0];
  } else {
    const createBuilding = await supabase(
      "buildings",
      {
        method: "POST",
        headers: {
          Prefer: "return=representation"
        },
        body: JSON.stringify({
          city_id: city.id,
          building_type: buildingType,
          level: 2
        })
      }
    );

    if (!createBuilding.ok) {
      return send(res, 500, {
        success: false,
        message: "Bina oluşturulamadı."
      });
    }

    building = createBuilding.data[0];
  }

  const updateCity = await supabase(
    "cities?id=eq." +
      encodeURIComponent(city.id),
    {
      method: "PATCH",
      headers: {
        Prefer: "return=representation"
      },
      body: JSON.stringify({
        metal: city.metal - cost.metal,
        energy: city.energy - cost.energy,
        water: city.water - cost.water,
        crystal: city.crystal - cost.crystal
      })
    }
  );

  if (!updateCity.ok) {
    return send(res, 500, {
      success: false,
      message: "Kaynaklar güncellenemedi."
    });
  }

  return send(res, 200, {
    success: true,
    message: buildingType + " geliştirildi.",
    city: updateCity.data[0],
    building: building
  });
}

async function getWorldPlayers(req, res) {
  const authHeader = req.headers.authorization || "";

  const token = authHeader.startsWith("Bearer ")
    ? authHeader.slice(7)
    : "";

  if (!token) {
    return send(res, 401, {
      success: false,
      message: "Oturum gerekli."
    });
  }

  const payload = verifyToken(token);

  if (!payload || !payload.id) {
    return send(res, 401, {
      success: false,
      message: "Geçersiz oturum."
    });
  }

  const citiesResult = await supabase(
    "cities?select=id,player_id,name,level"
  );

  if (!citiesResult.ok) {
    return send(res, 500, {
      success: false,
      message: "Koloniler alınamadı."
    });
  }

  const playersResult = await supabase(
    "players?select=id,username"
  );

  if (!playersResult.ok) {
    return send(res, 500, {
      success: false,
      message: "Oyuncular alınamadı."
    });
  }

  const cities = citiesResult.data || [];
  const playerRows = playersResult.data || [];

  const playerMap = {};

  for (const player of playerRows) {
    playerMap[player.id] = player.username;
  }

  const players = cities.map(function(city) {
    return {
      id: city.id,
      player_id: city.player_id,
      username: playerMap[city.player_id] || "Oyuncu",
      name: city.name,
      level: city.level
    };
  });

  return send(res, 200, {
    success: true,
    players: players
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

    if (action === "world") {
      return await getWorldPlayers(req, res);
    }

    if (action === "upgrade") {
      return await upgradeBuilding(req, res);
    }

    if (action === "army") {
      return await produceArmy(req, res);
    }

    if (action === "attack") {
      return await attackPlayer(req, res);
    }

    if (action === "reports") {
      return await getBattleReports(req, res);
    }

    if (action === "research") {
      return await getResearch(req, res);
    }

    if (action === "createalliance") {
      return await createAlliance(req, res);
    }

    if (action === "alliances") {
      return await getAlliances(req, res);
    }

    if (action === "joinalliance") {
      return await joinAlliance(req, res);
    }
    if (action === "leavealliance") {
  return await leaveAlliance(req, res);
}

    if (action === "upgraderesearch") {
      return await upgradeResearch(req, res);
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
