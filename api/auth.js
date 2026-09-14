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
  const method = String(options.method || "GET").toUpperCase();

  // Yalnızca güvenli GET/SELECT istekleri tekrar denenir.
  // POST / RPC / PATCH / DELETE kesinlikle otomatik tekrar edilmez.
  const canRetry = method === "GET";
  const maxAttempts = canRetry ? 2 : 1;

  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10000);

    try {
      const response = await fetch(
        SUPABASE_URL + "/rest/v1/" + path,
        {
          ...options,
          signal: controller.signal,
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

      const retryableStatus =
        response.status === 408 ||
        response.status === 429 ||
        response.status === 500 ||
        response.status === 502 ||
        response.status === 503 ||
        response.status === 504;

      if (
        canRetry &&
        retryableStatus &&
        attempt < maxAttempts - 1
      ) {
        await new Promise(resolve =>
          setTimeout(resolve, 250)
        );
        continue;
      }

      return {
        ok: response.ok,
        status: response.status,
        data
      };
    } catch (error) {
      if (canRetry && attempt < maxAttempts - 1) {
        await new Promise(resolve =>
          setTimeout(resolve, 250)
        );
        continue;
      }

      const timedOut = error?.name === "AbortError";

      console.error(
        timedOut
          ? "Supabase istek zaman aşımı:"
          : "Supabase bağlantı hatası:",
        path,
        error
      );

      return {
        ok: false,
        status: timedOut ? 504 : 503,
        data: {
          message: timedOut
            ? "Veritabanı isteği zaman aşımına uğradı."
            : "Veritabanına bağlanılamadı."
        }
      };
    } finally {
      clearTimeout(timeout);
    }
  }
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

  if (username.length > 24) {
    return send(res, 400, {
      success: false,
      message: "Kullanıcı adı en fazla 24 karakter olmalı."
    });
  }

  if (!/^[A-Za-zÇĞİÖŞÜçğıöşü0-9_-]+$/.test(username)) {
    return send(res, 400, {
      success: false,
      message: "Kullanıcı adı yalnızca harf, rakam, _ ve - içerebilir."
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

  const cityResult = await supabase("rpc/nexora_create_starting_city", {
    method: "POST",
    body: JSON.stringify({
      p_player_id: Number(player.id),
      p_name: "Yeni Koloni"
    })
  });

  if (!cityResult.ok || cityResult.data?.success !== true) {
    console.error(
      "Başlangıç kolonisi oluşturma hatası:",
      cityResult.data
    );

    // Kayıt yarım kalmasın: şehir oluşturulamadıysa yeni oyuncuyu geri al.
    await supabase(
      "players?id=eq." + encodeURIComponent(player.id),
      { method: "DELETE" }
    );

    return send(res, 500, {
      success: false,
      message: cityResult.data?.message || "Başlangıç kolonisi oluşturulamadı."
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

function authPlayerId(req) {
  const authHeader = String(req.headers.authorization || "");
  if (!authHeader.startsWith("Bearer ")) return null;
  const decoded = verifyToken(authHeader.slice(7).trim());
  if (!decoded || !decoded.id) return null;
  const id = Number(decoded.id);
  return Number.isInteger(id) ? id : null;
}

const UNIT_CONFIG = {
  piyade: { label: "Piyade", metal: 100, energy: 20, population: 1, train: 20 },
  savunma: { label: "Savunma Birliği", metal: 150, energy: 40, population: 1, train: 24 },
  saldiri: { label: "Saldırı Birliği", metal: 200, energy: 75, population: 1, train: 28 },
  okcu: { label: "Okçu", metal: 220, energy: 90, population: 1, train: 30 },
  tank: { label: "Tank", metal: 700, energy: 220, population: 3, train: 55 },
  hava: { label: "Hava Birliği", metal: 650, energy: 260, population: 2, train: 50 }
};

async function getUnitLevelStats(unitType, level) {
  const safeLevel = Math.max(1, Math.min(15, Number(level) || 1));
  const result = await supabase("unit_levels?select=unit_type,level,attack,defense,hp,speed&unit_type=eq." + encodeURIComponent(unitType) + "&level=eq." + encodeURIComponent(safeLevel) + "&limit=1");
  return result.ok && result.data?.[0] ? result.data[0] : null;
}

async function hydrateArmyStats(army) {
  const hydrated = [];
  for (const unit of (army || [])) {
    const level = Math.max(1, Math.min(15, Number(unit.level) || 1));
    const stats = await getUnitLevelStats(unit.unit_type, level);
    if (!stats) continue;
    hydrated.push({ ...unit, level, attack:Number(stats.attack), defense:Number(stats.defense), hp:Number(stats.hp), speed:Number(stats.speed), population_cost:Number(unit.population_cost || UNIT_CONFIG[unit.unit_type]?.population || 1) });
  }
  return hydrated;
}

function buildingLevel(buildings, name, slot = 1) {
  const b = (buildings || []).find(
    x =>
      x.building_type === name &&
      Math.max(1, Number(x.slot) || 1) === slot
  );
  return b ? Math.max(0, Number(b.level) || 0) : 0;
}

function buildingTotalLevel(buildings, name) {
  return (buildings || []).reduce(
    (sum, b) =>
      b.building_type === name
        ? sum + Math.max(0, Number(b.level) || 0)
        : sum,
    0
  );
}

function storageCapacity(buildings) {
  const level = buildingTotalLevel(buildings, "Depo");
  return 5000 + level * 2500;
}

function crystalStorageCapacity(buildings) {
  const level = buildingLevel(buildings, "Kristal Deposu");
  return 3000 + level * 1500;
}

function housingCapacity(buildings) {
  const level = buildingLevel(buildings, "Konut");
  return 100 + level * 50;
}

function armyCapacity(buildings) {
  const level = buildingLevel(buildings, "Kışla");
  return 50 + level * 50;
}

function buildingMaxLevel(name) {
  const max = {
    "Merkez Bina": 30,
    "Metal Madeni": 30,
    "Enerji Santrali": 30,
    "Su Arıtma": 30,
    "Kristal Madeni": 30,
    "Kışla": 30,
    "Depo": 25,
    "Kristal Deposu": 25,
    "Konut": 30,
    "Sur": 25,
    "Savunma Kulesi": 20,
    "Gözcü Kulesi": 20
  };
  return max[name] || 30;
}

function defenseBonus(buildings) {
  const wall = buildingLevel(buildings, "Sur");
  return 1 + wall * 0.05;
}

function totalPopulation(units, queue, activeMissionPopulation = 0) {
  let total = Math.max(0, Number(activeMissionPopulation) || 0);
  for (const u of (units || [])) {
    const cfg = UNIT_CONFIG[u.unit_type] || { population: Number(u.population_cost || 1) };
    total += Number(u.quantity || 0) * Number(cfg.population || 1);
  }
  for (const q of (queue || [])) {
    const cfg = UNIT_CONFIG[q.unit_type] || { population: 1 };
    total += Number(q.quantity || 0) * Number(cfg.population || 1);
  }
  return total;
}

async function syncProductionQueue(playerId, cityId) {
  const result = await supabase("rpc/nexora_complete_unit_training", {
    method: "POST", body: JSON.stringify({ p_player_id: Number(playerId), p_city_id: Number(cityId) })
  });
  return { ok: result.ok && result.data?.success === true, queue: result.data?.queue || [] };
}

async function finalizeBuilding(building) {
  if (!building || !building.is_under_construction || !building.upgrade_ready_at) return building;
  if (new Date(building.upgrade_ready_at).getTime() > Date.now()) return building;
  const updated = await supabase("buildings?id=eq." + encodeURIComponent(building.id) + "&is_under_construction=eq.true&upgrade_ready_at=eq." + encodeURIComponent(building.upgrade_ready_at) + "&level=eq." + encodeURIComponent(building.level), {
    method: "PATCH", headers: { Prefer: "return=representation" },
    body: JSON.stringify({ level: Number(building.level || 0) + 1, is_under_construction: false, upgrade_ready_at: null })
  });
  if (updated.ok && updated.data?.[0]) return updated.data[0];
  const current = await supabase("buildings?select=*&id=eq." + encodeURIComponent(building.id));
  return current.ok && current.data?.[0] ? current.data[0] : building;
}

async function finalizeResearch(research) {
  if (!research || !research.upgrade_ready_at) return research;
  if (new Date(research.upgrade_ready_at).getTime() > Date.now()) return research;
  const column = research.pending_column;
  if (!column) return research;
  const updated = await supabase("research?id=eq." + encodeURIComponent(research.id) + "&upgrade_ready_at=eq." + encodeURIComponent(research.upgrade_ready_at) + "&pending_column=eq." + encodeURIComponent(column), {
    method: "PATCH", headers: { Prefer: "return=representation" },
    body: JSON.stringify({ [column]: Number(research[column] || 0) + 1, upgrade_ready_at: null, pending_column: null })
  });
  if (updated.ok && updated.data?.[0]) return updated.data[0];
  const current = await supabase("research?select=*&id=eq." + encodeURIComponent(research.id));
  return current.ok && current.data?.[0] ? current.data[0] : research;
}

function capResource(value, cap) { return Math.max(0, Math.min(Number(value || 0), cap)); }

async function getCity(req, res) {
  const playerId = authPlayerId(req);
  if (playerId === null) return send(res, 401, { success: false, message: "Oturum bulunamad\u0131." });

  const result = await supabase("cities?select=*&player_id=eq." + encodeURIComponent(playerId) + "&limit=1");
  if (!result.ok) return send(res, 500, { success: false, message: "Koloni veritaban\u0131ndan al\u0131namad\u0131." });

  if (!result.data?.[0]) {
    const createResult = await supabase("cities", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify({
      player_id: playerId, name: "Yeni Koloni", level: 1, metal: 1000, energy: 500, water: 500, crystal: 250
    }) });
    if (!createResult.ok) return send(res, 500, { success: false, message: "Koloni olu\u015fturulamad\u0131." });
    return send(res, 200, { success: true, city: createResult.data[0], buildings: [], units: [], productionQueue: [] });
  }

  let city = result.data[0];
  const buildingsResult = await supabase("buildings?select=*&city_id=eq." + encodeURIComponent(city.id) + "&order=building_type.asc,slot.asc");
  if (!buildingsResult.ok) return send(res, 500, { success: false, message: "Bina verileri al\u0131namad\u0131." });
  let buildings = [];
  for (const b of (buildingsResult.data || [])) buildings.push(await finalizeBuilding(b));

  const production = await syncProductionQueue(playerId, city.id);
  if (!production.ok) return send(res, 500, { success: false, message: "\u00dcretim kuyru\u011fu al\u0131namad\u0131." });

  const productionSync = await supabase("rpc/nexora_sync_city_production", {
    method: "POST",
    body: JSON.stringify({ p_player_id: playerId })
  });
  if (!productionSync.ok || productionSync.data?.success === false || !productionSync.data?.city) {
    console.error("Atomik \u00fcretim senkronizasyonu hatas\u0131:", productionSync.data);
    return send(res, 503, { success: false, message: "Koloni \u00fcretimi senkronize edilemedi." });
  }
  city = productionSync.data.city;

  const populationSnapshot = await supabase("rpc/nexora_sync_city_population_snapshot", {
    method: "POST",
    body: JSON.stringify({ p_player_id: playerId })
  });
  if (!populationSnapshot.ok || populationSnapshot.data?.success === false || !populationSnapshot.data?.city) {
    console.error("Atomik n\u00fcfus snapshot hatas\u0131:", populationSnapshot.data);
    return send(res, 503, { success: false, message: "Koloni n\u00fcfusu senkronize edilemedi." });
  }

  city = populationSnapshot.data.city;
  const units = Array.isArray(populationSnapshot.data.units) ? populationSnapshot.data.units : [];
  const productionQueue = Array.isArray(populationSnapshot.data.queue) ? populationSnapshot.data.queue : [];
  const population = Math.max(0, Number(populationSnapshot.data.population ?? city.population) || 0);
  const populationCap = Math.max(0, Number(populationSnapshot.data.population_capacity ?? city.population_capacity) || 0);
  const armyCap = Math.max(0, Number(populationSnapshot.data.army_capacity ?? city.army_capacity) || 0);

  const researchResult = await supabase("research?select=production_level,crystal_level&player_id=eq." + encodeURIComponent(playerId) + "&limit=1");
  const research = researchResult.ok && researchResult.data?.[0] ? researchResult.data[0] : {};
  const prodMultiplier = 1 + Number(research.production_level || 0) * 0.10;
  const crystalMultiplier = 1 + Number(research.crystal_level || 0) * 0.08;
  const metalRate = buildingTotalLevel(buildings, "Metal Madeni") * 10 * prodMultiplier;
  const energyRate = buildingTotalLevel(buildings, "Enerji Santrali") * 10 * prodMultiplier;
  const waterRate = buildingTotalLevel(buildings, "Su Ar\u0131tma") * 10 * prodMultiplier;
  const crystalRate = buildingTotalLevel(buildings, "Kristal Madeni") * 5 * crystalMultiplier;
  const resourceCap = storageCapacity(buildings);
  const crystalCap = crystalStorageCapacity(buildings);

  return send(res, 200, {
    success: true,
    city: { ...city, population, population_capacity: populationCap, army_capacity: armyCap, storage_capacity: resourceCap, crystal_storage_capacity: crystalCap, defense_bonus: defenseBonus(buildings) },
    buildings,
    units,
    productionQueue,
    production: { metalPerMinute: metalRate, energyPerMinute: energyRate, waterPerMinute: waterRate, crystalPerMinute: crystalRate },
    capacities: { metal_capacity: resourceCap, energy_capacity: resourceCap, water_capacity: resourceCap, crystal_capacity: crystalCap, population_capacity: populationCap, army_capacity: armyCap, defense_bonus: defenseBonus(buildings) }
  });
}
async function spendCityResources(playerId,cost={}){
  return await supabase("rpc/nexora_spend_city_resources",{
    method:"POST",
    body:JSON.stringify({
      p_player_id:Number(playerId),
      p_metal:Number(cost.metal||0),
      p_energy:Number(cost.energy||0),
      p_water:Number(cost.water||0),
      p_crystal:Number(cost.crystal||0)
    })
  });
}

async function produceArmy(req, res) {
  const playerId = authPlayerId(req);

  if (playerId === null) {
    return send(res, 401, {
      success: false,
      message: "Oturum bulunamadı."
    });
  }

  const body = await readBody(req);

  const unitType = String(
    body.unitType || ""
  ).trim();

  const cfg = UNIT_CONFIG[unitType];

  if (!cfg) {
    return send(res, 400, {
      success: false,
      message: "Geçersiz birlik türü."
    });
  }

  let requestedQuantity = 1;

  const hasQuantity =
    Object.prototype.hasOwnProperty.call(
      body,
      "quantity"
    );

  if (hasQuantity) {
    if (
      body.quantity === null ||
      String(body.quantity)
        .trim()
        .toLowerCase() === "max"
    ) {
      requestedQuantity = null;
    } else {
      const quantity =
        Number(body.quantity);

      if (
        !Number.isInteger(quantity) ||
        quantity <= 0 ||
        quantity > 1000000
      ) {
        return send(res, 400, {
          success: false,
          message: "Geçersiz üretim adedi."
        });
      }

      requestedQuantity = quantity;
    }
  }

  const cityResult = await supabase(
    "cities?select=*&player_id=eq." +
      encodeURIComponent(playerId) +
      "&limit=1"
  );

  if (
    !cityResult.ok ||
    !cityResult.data?.[0]
  ) {
    return send(res, 404, {
      success: false,
      message: "Koloni bulunamadı."
    });
  }

  const city = cityResult.data[0];

  const production =
    await syncProductionQueue(
      playerId,
      city.id
    );

  if (!production.ok) {
    return send(res, 500, {
      success: false,
      message: "Üretim kuyruğu okunamadı."
    });
  }

  const result = await supabase(
    "rpc/nexora_start_unit_training_bulk",
    {
      method: "POST",
      body: JSON.stringify({
        p_player_id: Number(playerId),
        p_city_id: Number(city.id),
        p_type: unitType,
        p_requested_quantity:
          requestedQuantity
      })
    }
  );

  if (!result.ok) {
    console.error(
      "Toplu birlik üretimi başlatılamadı:",
      result.data
    );

    return send(res, 500, {
      success: false,
      message: "Üretim başlatılamadı."
    });
  }

  if (result.data?.success !== true) {
    return send(
      res,
      400,
      result.data || {
        success: false,
        message: "Üretim başlatılamadı."
      }
    );
  }

  const acceptedQuantity =
    Math.max(
      0,
      Number(
        result.data?.acceptedQuantity ||
        result.data?.production?.quantity ||
        0
      )
    );

  const message =
    acceptedQuantity > 1
      ? cfg.label +
        " ×" +
        acceptedQuantity +
        " üretim sırasına alındı."
      : cfg.label +
        " üretim sırasına alındı.";

  return send(res, 200, {
    ...result.data,
    message
  });
}
async function upgradeUnit(req, res) {
  const authHeader = String(req.headers.authorization || "");

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

  if (!unitType) {
    return send(res, 400, {
      success: false,
      message: "Birlik türü belirtilmedi."
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

  const unitResult = await supabase(
    "units?select=*&city_id=eq." +
      encodeURIComponent(city.id) +
      "&unit_type=eq." +
      encodeURIComponent(unitType) +
      "&limit=1"
  );

  if (!unitResult.ok) {
    return send(res, 500, {
      success: false,
      message: "Birlik verisi alınamadı."
    });
  }

  if (!unitResult.data || !unitResult.data[0]) {
    return send(res, 404, {
      success: false,
      message: "Bu türden birlik bulunamadı."
    });
  }

  const unit = unitResult.data[0];

  const currentLevel = Math.max(
    1,
    Number(unit.level) || 1
  );

  if (currentLevel >= 15) {
    return send(res, 400, {
      success: false,
      message: "Bu birlik zaten 15. seviyede."
    });
  }

  const nextLevel = currentLevel + 1;

  const levelResult = await supabase(
    "unit_levels?select=*&unit_type=eq." +
      encodeURIComponent(unitType) +
      "&level=eq." +
      encodeURIComponent(nextLevel) +
      "&limit=1"
  );

  if (
    !levelResult.ok ||
    !levelResult.data ||
    !levelResult.data[0]
  ) {
    return send(res, 500, {
      success: false,
      message: "Bir sonraki seviye verisi bulunamadı."
    });
  }

  const cost = {
    metal: currentLevel * 500,
    energy: currentLevel * 100,
    crystal: currentLevel * 50
  };

  if (
    Number(city.metal) < cost.metal ||
    Number(city.energy) < cost.energy ||
    Number(city.crystal) < cost.crystal
  ) {
    return send(res, 400, {
      success: false,
      message: "Seviye yükseltmek için yeterli kaynak yok.",
      cost
    });
  }

  const upgraded = await supabase(
    "rpc/nexora_upgrade_unit_atomic",
    {
      method: "POST",
      body: JSON.stringify({
        p_player_id: Number(decoded.id),
        p_city_id: Number(city.id),
        p_unit_id: Number(unit.id),
        p_level: currentLevel
      })
    }
  );

  if (!upgraded.ok) {
    return send(res, 500, {
      success: false,
      message: "Birlik seviyesi güncellenemedi."
    });
  }

  if (upgraded.data?.success !== true) {
    return send(
      res,
      400,
      upgraded.data || {
        success: false,
        message: "Birlik seviyesi güncellenemedi."
      }
    );
  }

  return send(res, 200, {
    success: true,
    message: "Birlik seviyesi yükseltildi.",
    unit: upgraded.data.unit,
    city: upgraded.data.city,
    cost
  });
}
async function moveColony(req, res) {
  const playerId = authPlayerId(req);
  if (playerId === null) {
    return send(res, 401, {
      success: false,
      message: "Oturum bulunamad\u0131."
    });
  }

  const body = await readBody(req);
  const x = Number(body.x);
  const y = Number(body.y);

  if (
    !Number.isInteger(x) ||
    !Number.isInteger(y) ||
    x < 1 || x > 100 ||
    y < 1 || y > 100
  ) {
    return send(res, 400, {
      success: false,
      message: "X ve Y koordinatlar\u0131 1-100 aras\u0131nda tam say\u0131 olmal\u0131."
    });
  }

  const moved = await supabase("rpc/nexora_move_colony_atomic", {
    method: "POST",
    body: JSON.stringify({
      p_player_id: Number(playerId),
      p_x: x,
      p_y: y
    })
  });

  if (!moved.ok) {
    console.error("Atomik koloni tasima hatasi:", moved.data);
    return send(res, 500, {
      success: false,
      message: "Koloni koordinat\u0131 g\u00fcncellenemedi."
    });
  }

  if (moved.data?.success !== true) {
    const status = moved.data?.code === "CITY_NOT_FOUND" ? 404 : 400;
    return send(
      res,
      status,
      moved.data || {
        success: false,
        message: "Koloni ta\u015f\u0131namad\u0131."
      }
    );
  }

  return send(res, 200, {
    success: true,
    message: moved.data.message || "Koloni ta\u015f\u0131nd\u0131.",
    city: moved.data.city
  });
}


const COMBAT_ROLE_V2 = {
  piyade:{attack:1.00,defense:1.00,hp:1.00,loss:1.00},
  savunma:{attack:0.92,defense:1.15,hp:1.08,loss:0.82},
  saldiri:{attack:1.14,defense:0.90,hp:0.96,loss:1.08},
  okcu:{attack:1.18,defense:0.88,hp:0.94,loss:1.06},
  tank:{attack:1.03,defense:1.25,hp:1.15,loss:0.68},
  hava:{attack:1.10,defense:0.96,hp:1.02,loss:0.90}
};
const MATCHUP_V2 = {
  piyade:{tank:0.88,hava:0.94,okcu:1.04,saldiri:0.98,savunma:1.02},
  savunma:{piyade:1.05,saldiri:1.08,okcu:0.96,tank:0.90,hava:0.94},
  saldiri:{piyade:1.04,savunma:1.12,tank:1.06,hava:0.92,okcu:0.98},
  okcu:{piyade:1.06,savunma:1.04,tank:1.12,hava:0.82,saldiri:1.03},
  tank:{piyade:1.12,savunma:1.10,okcu:0.90,saldiri:0.96,hava:0.88},
  hava:{piyade:1.06,savunma:1.08,tank:1.18,saldiri:1.10,okcu:1.12}
};
function matchupMultiplier(attackerType, defenderType){
  return Number(MATCHUP_V2[attackerType]?.[defenderType] || 1);
}
function safeBattleResult(value){
  if(value && typeof value === 'object') return String(value.result || '');
  return String(value || '');
}
function calculateBattlePoints(result, attackPower, defensePower){
  const a=Math.max(0,Number(attackPower)||0), d=Math.max(0,Number(defensePower)||0);
  const margin=a+d>0?Math.min(1,Math.abs(a-d)/(a+d)):0;
  if(result==='Zafer') return Math.round(100+100*margin);
  if(result==='Beraberlik') return 10;
  return 0;
}
function regionForCoordinates(x,y){
  const regions=[
    {name:'Çöl Bölgesi',x:10,y:18,bonus:'Metal üretimi +5%'},
    {name:'Orman Bölgesi',x:42,y:12,bonus:'Su üretimi +5%'},
    {name:'Buz Bölgesi',x:91,y:17,bonus:'Enerji üretimi +5%'},
    {name:'Dağ Bölgesi',x:30,y:83,bonus:'Savunma +5%'},
    {name:'Volkanik Bölge',x:72,y:85,bonus:'Kristal üretimi +5%'},
    {name:'Okyanus',x:95,y:55,bonus:'Seyahat süresi -5%'}
  ];
  let best=regions[0], dist=Infinity;
  for(const r of regions){const dd=Math.hypot(Number(x)-r.x,Number(y)-r.y);if(dd<dist){dist=dd;best=r;}}
  return best;
}

async function createMilitaryMission(req, res) {
  const playerId = authPlayerId(req);
  if (playerId === null) return send(res,401,{success:false,message:"Oturum bulunamadı."});

  const body = await readBody(req);
  const targetPlayerId = Number(body.targetPlayerId);
  if (!Number.isInteger(targetPlayerId) || targetPlayerId === playerId) {
    return send(res,400,{success:false,message:"Geçersiz hedef oyuncu."});
  }

  const requestedUnits = body.units && typeof body.units === "object" && !Array.isArray(body.units)
    ? body.units
    : null;
  if (!requestedUnits) {
    return send(res,400,{success:false,message:"Geçersiz birlik seçimi."});
  }

  let hasRequestedUnit = false;
  for (const [type, rawQuantity] of Object.entries(requestedUnits)) {
    if (!Object.prototype.hasOwnProperty.call(UNIT_CONFIG, type)) {
      return send(res,400,{success:false,message:"Geçersiz birlik türü: "+type});
    }
    const quantity = Number(rawQuantity);
    if (!Number.isSafeInteger(quantity) || quantity < 0 || quantity > 2147483647) {
      return send(res,400,{success:false,message:type+" için birlik miktarı 0 veya pozitif tam sayı olmalı."});
    }
    if (quantity > 0) hasRequestedUnit = true;
  }
  if (!hasRequestedUnit) {
    return send(res,400,{success:false,message:"En az bir birlik miktarı seçmelisin."});
  }

  const [attackerCityResult,targetCityResult] = await Promise.all([
    supabase("cities?select=*&player_id=eq."+encodeURIComponent(playerId)+"&limit=1"),
    supabase("cities?select=*&player_id=eq."+encodeURIComponent(targetPlayerId)+"&limit=1")
  ]);
  if (!attackerCityResult.ok || !attackerCityResult.data?.[0]) {
    return send(res,404,{success:false,message:"Saldıran koloni bulunamadı."});
  }
  if (!targetCityResult.ok || !targetCityResult.data?.[0]) {
    return send(res,404,{success:false,message:"Hedef koloni bulunamadı."});
  }

  const attackerCity = attackerCityResult.data[0];
  const targetCity = targetCityResult.data[0];

  const unitsResult = await supabase(
    "units?select=*&city_id=eq."+encodeURIComponent(attackerCity.id)+"&order=id.asc"
  );
  if (!unitsResult.ok) {
    return send(res,500,{success:false,message:"Ordu verisi alınamadı."});
  }

  const unitRows = new Map();
  for (const unit of (unitsResult.data || [])) {
    const type = String(unit.unit_type);
    if (!unitRows.has(type)) unitRows.set(type, unit);
  }

  let army = [];
  for (const [type, rawQuantity] of Object.entries(requestedUnits)) {
    const quantity = Number(rawQuantity);
    if (quantity === 0) continue;

    const row = unitRows.get(type);
    if (!row || Number(row.quantity || 0) < quantity) {
      return send(res,400,{success:false,message:type+" için gönderilecek miktar mevcut ordudan fazla."});
    }

    army.push({
      unit_type:type,
      quantity,
      level:Number(row.level || 1),
      attack:Number(row.attack || 0),
      defense:Number(row.defense || 0),
      hp:Number(row.hp || 0),
      speed:Number(row.speed || 100),
      population_cost:Number(row.population_cost || 1)
    });
  }

  const requestedArmyCount = army.length;
  army = await hydrateArmyStats(army);
  if (!army.length || army.length !== requestedArmyCount) {
    return send(res,500,{success:false,message:"Birlik seviye verisi alınamadı."});
  }

  const distance = Math.sqrt(
    Math.pow(Number(targetCity.coordinate_x || 0) - Number(attackerCity.coordinate_x || 0), 2) +
    Math.pow(Number(targetCity.coordinate_y || 0) - Number(attackerCity.coordinate_y || 0), 2)
  );

  const researchResult = await supabase(
    "research?select=travel_speed_level,general_power_level,unit_attack_level,unit_defense_level,unit_hp_level&player_id=eq."+
    encodeURIComponent(playerId)+"&limit=1"
  );
  const research = researchResult.ok && researchResult.data?.[0]
    ? researchResult.data[0]
    : {};

  const fleetSpeed = Math.max(25, Math.min(...army.map(u => Number(u.speed || 100))));
  const speedResearch = Math.max(0.25, 1 - Number(research.travel_speed_level || 0) * 0.05);
  // Base military travel speed: 2 map-km per second.
  // Travel-speed research can reduce the time further, but never below 1 second.
  const travelSeconds = Math.max(
    1,
    Math.ceil((Math.max(0, distance) / 2) * speedResearch)
  );
  const attackResearch =
    (1 + Number(research.general_power_level || 0) * 0.05) *
    (1 + Number(research.unit_attack_level || 0) * 0.05);
  const hpResearch = 1 + Number(research.unit_hp_level || 0) * 0.05;
  const attackPower = Math.round(
    army.reduce(
      (sum, u) => sum + u.quantity * u.attack * attackResearch + u.quantity * u.hp * 0.15 * hpResearch,
      0
    )
  );

  const startedResult = await supabase("rpc/nexora_start_military_mission", {
    method:"POST",
    body:JSON.stringify({
      p_attacker_player_id:Number(playerId),
      p_defender_player_id:Number(targetPlayerId),
      p_attacker_city_id:Number(attackerCity.id),
      p_defender_city_id:Number(targetCity.id),
      p_army:army,
      p_attack_power:attackPower,
      p_depart_x:Number(attackerCity.coordinate_x || 0),
      p_depart_y:Number(attackerCity.coordinate_y || 0),
      p_target_x:Number(targetCity.coordinate_x || 0),
      p_target_y:Number(targetCity.coordinate_y || 0),
      p_travel_seconds:travelSeconds,
      p_fleet_speed:fleetSpeed
    })
  });

  if (!startedResult.ok) {
    console.error("Atomik sefer başlatma RPC hatası:", startedResult.data);
    return send(res,500,{success:false,message:"Sefer oluşturulamadı."});
  }

  const started = startedResult.data || {};
  if (started.success !== true) {
    const code = String(started.code || "");
    const status = code === "ACTIVE_MISSION"
      ? 409
      : (code === "CITY_NOT_FOUND" || code === "TARGET_CITY_NOT_FOUND")
        ? 404
        : 400;
    return send(res,status,{
      success:false,
      code:code || "MISSION_START_FAILED",
      message:started.message || "Sefer başlatılamadı."
    });
  }

  const mission = started.mission || {};
  const missionId = Number(mission.id);
  if (!Number.isSafeInteger(missionId) || missionId <= 0) {
    console.error("Atomik sefer RPC geçersiz mission döndürdü:", started);
    return send(res,500,{success:false,message:"Sefer oluşturulamadı."});
  }

  const arriveAt = mission.arrive_at || new Date(Date.now() + travelSeconds * 1000).toISOString();
  return send(res,200,{
    success:true,
    message:"⚔️ Ordu sefere çıktı.",
    mission:{
      id:missionId,
      status:String(mission.status || "traveling"),
      arriveAt,
      travelSeconds:Number(mission.travel_seconds || travelSeconds),
      distance:Math.round(distance)
    }
  });
}

async function completeMissionReturn(mission,res,playerId){
  const returnedResult=await supabase("rpc/nexora_complete_military_return",{
    method:"POST",
    body:JSON.stringify({
      p_player_id:Number(playerId),
      p_mission_id:Number(mission.id)
    })
  });

  if(!returnedResult.ok){
    console.error("Atomik sefer dönüş RPC hatası:",returnedResult.data);
    return send(res,500,{success:false,message:"Sefer dönüşü tamamlanamadı."});
  }

  const returned=returnedResult.data||{};
  if(returned.success!==true){
    const code=String(returned.code||"");
    const status=code==="FORBIDDEN"?403:code==="MISSION_NOT_FOUND"?404:400;
    return send(res,status,{
      success:false,
      code:code||"MISSION_RETURN_FAILED",
      message:returned.message||"Sefer dönüşü tamamlanamadı."
    });
  }

  return send(res,200,{success:true,mission:returned.mission||mission});
}

async function getMilitaryMission(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum bulunamadı."});
  const missionId=Number(req.query.id); if(!Number.isInteger(missionId))return send(res,400,{success:false,message:"Geçersiz sefer."});
  const m=await supabase("military_missions?id=eq."+encodeURIComponent(missionId)+"&limit=1"); if(!m.ok||!m.data?.[0])return send(res,404,{success:false,message:"Sefer bulunamadı."});
  let mission=m.data[0]; if(playerId!==Number(mission.attacker_player_id)&&playerId!==Number(mission.defender_player_id))return send(res,403,{success:false,message:"Bu sefere erişemezsin."});
  if(mission.status==="completed")return send(res,200,{success:true,mission});
  let remaining=Math.ceil((new Date(mission.arrive_at).getTime()-Date.now())/1000);
  if(mission.status==="returning"&&remaining<=0)return completeMissionReturn(mission,res,playerId);
  if(mission.status==="returning"||remaining>0)return send(res,200,{success:true,mission:{id:mission.id,status:mission.status,arriveAt:mission.arrive_at,remainingSeconds:Math.max(0,remaining),result:mission.result||null,attack_power:mission.attack_power||0}});

  if(mission.status==="traveling"){
    const claim=await supabase("military_missions?id=eq."+encodeURIComponent(mission.id)+"&status=eq.traveling",{method:"PATCH",headers:{Prefer:"return=representation"},body:JSON.stringify({status:"resolving"})});
    if(!claim.ok||!claim.data?.[0]){
      const reread=await supabase("military_missions?id=eq."+encodeURIComponent(mission.id)+"&limit=1");
      return send(res,200,{success:true,mission:reread.data?.[0]||mission});
    }
    mission=claim.data[0];
  } else if(mission.status!=="resolving"){
    return send(res,409,{success:false,message:"Sefer durumu çözümlenemiyor."});
  }

  const battleSnapshotResult=await supabase("rpc/nexora_prepare_military_battle_snapshot",{
    method:"POST",
    body:JSON.stringify({
      p_player_id:Number(playerId),
      p_mission_id:Number(mission.id)
    })
  });

  if(!battleSnapshotResult.ok){
    console.error("Atomik battle snapshot RPC hatasi:",battleSnapshotResult.data);
    return send(res,500,{success:false,message:"Savas durumu hazirlanamadi."});
  }

  const battleSnapshot=battleSnapshotResult.data||{};
  if(battleSnapshot.success!==true){
    const code=String(battleSnapshot.code||"");
    const status=code==="FORBIDDEN"?403:code==="MISSION_NOT_FOUND"?404:code==="BATTLE_NOT_READY"?409:400;
    return send(res,status,{
      success:false,
      code:code||"BATTLE_SNAPSHOT_FAILED",
      message:battleSnapshot.message||"Savas durumu hazirlanamadi."
    });
  }

  if(battleSnapshot.alreadyResolved===true){
    return send(res,200,{success:true,mission:battleSnapshot.mission||mission});
  }

  mission=battleSnapshot.mission||mission;
  const rawDefenders=Array.isArray(battleSnapshot.defenderUnits)?battleSnapshot.defenderUnits:[];
  const defR=battleSnapshot.defenderResearch&&typeof battleSnapshot.defenderResearch==="object"
    ?battleSnapshot.defenderResearch:{};
  const defB=Array.isArray(battleSnapshot.defenderBuildings)?battleSnapshot.defenderBuildings:[];
  const attR=battleSnapshot.attackerResearch&&typeof battleSnapshot.attackerResearch==="object"
    ?battleSnapshot.attackerResearch:{};
  const army=await hydrateArmyStats(Array.isArray(mission.army)?mission.army:[]);
  const defenders=await hydrateArmyStats(rawDefenders.filter(u=>Number(u.quantity||0)>0).map(u=>({id:Number(u.id),unit_type:u.unit_type,quantity:Number(u.quantity||0),level:Number(u.level||1),population_cost:Number(u.population_cost||1)})));
  const roleOf=type=>COMBAT_ROLE_V2[type]||COMBAT_ROLE_V2.piyade;
  const researchMul=r=>({general:1+Number(r.general_power_level||0)*0.05,combat:1+Number(r.combat_level||0)*0.05,attack:1+Number(r.unit_attack_level||0)*0.05,defense:1+Number(r.unit_defense_level||0)*0.05,hp:1+Number(r.unit_hp_level||0)*0.05});
  const am=researchMul(attR),dm={general:1+Number(defR.general_power_level||0)*0.05,combat:1+Number(defR.combat_level||0)*0.05,defense:1+Number(defR.unit_defense_level||0)*0.05,hp:1+Number(defR.unit_hp_level||0)*0.05};
  const defenderTotal=Math.max(1,defenders.reduce((s,u)=>s+Number(u.quantity||0),0));
  const attackerTotal=Math.max(1,army.reduce((s,u)=>s+Number(u.quantity||0),0));

  const attackerBreakdown=army.map(u=>{
    const r=roleOf(u.unit_type),q=Number(u.quantity||0),level=Math.max(1,Number(u.level||1));
    const levelMul=1+(level-1)*0.04;
    const base=(q*Number(u.attack||0)*r.attack*am.general*am.combat*am.attack + q*Number(u.hp||0)*0.15*r.hp*am.hp)*levelMul;
    const matchup=defenders.length?defenders.reduce((sum,d)=>sum+Number(d.quantity||0)*matchupMultiplier(u.unit_type,d.unit_type),0)/defenderTotal:1;
    const power=base*matchup;
    return {unit_type:u.unit_type,quantity:q,level,basePower:Math.round(base),matchupMultiplier:Number(matchup.toFixed(3)),power:Math.round(power)};
  });
  const defenderBreakdown=defenders.map(u=>{
    const r=roleOf(u.unit_type),q=Number(u.quantity||0),level=Math.max(1,Number(u.level||1));
    const levelMul=1+(level-1)*0.04;
    const base=(q*Number(u.defense||0)*r.defense*dm.general*dm.combat*dm.defense + q*Number(u.hp||0)*0.15*r.hp*dm.hp)*levelMul;
    const matchup=army.length?army.reduce((sum,a)=>sum+Number(a.quantity||0)*(2-matchupMultiplier(a.unit_type,u.unit_type)),0)/attackerTotal:1;
    const power=base*Math.max(0.75,matchup);
    return {unit_type:u.unit_type,quantity:q,level,basePower:Math.round(base),matchupMultiplier:Number(Math.max(0.75,matchup).toFixed(3)),power:Math.round(power)};
  });
  const rawAttackPower=attackerBreakdown.reduce((s,u)=>s+u.power,0);
  const wallBonus=defenseBonus(defB);
  const rawDefensePower=defenderBreakdown.reduce((s,u)=>s+u.power,0);
  const attackPower=Math.max(0,Math.round(rawAttackPower));
  const defensePower=Math.max(0,Math.round(rawDefensePower*wallBonus));
  const result=attackPower>defensePower?"Zafer":attackPower===defensePower?"Beraberlik":"Yenilgi";
  const ratio=attackPower+defensePower>0?Math.abs(attackPower-defensePower)/(attackPower+defensePower):0;
  const attackerLossBase=result==="Zafer"?0.18:result==="Beraberlik"?0.38:0.68;
  const defenderLossBase=result==="Zafer"?0.62:result==="Beraberlik"?0.38:0.18;
  const attackerLosses={},survivorArmy=[],defenderLosses={};
  for(const u of army){const r=roleOf(u.unit_type),q=Number(u.quantity||0),mod=Math.max(0.55,Math.min(1.45,1+(r.loss-1)*0.7)),loss=Math.min(q,Math.max(0,Math.ceil(q*attackerLossBase*mod*(1-0.12*ratio))));attackerLosses[u.unit_type]=(attackerLosses[u.unit_type]||0)+loss;survivorArmy.push({...u,quantity:q-loss});}
  for(const u of defenders){const r=roleOf(u.unit_type),q=Number(u.quantity||0),mod=Math.max(0.55,Math.min(1.45,1+(r.loss-1)*0.7)),loss=Math.min(q,Math.max(0,Math.ceil(q*defenderLossBase*mod*(1-0.12*ratio))));defenderLosses[u.unit_type]=(defenderLosses[u.unit_type]||0)+loss;}
  const outbound=Math.max(1,Math.round((new Date(mission.arrive_at).getTime()-new Date(mission.depart_at).getTime())/1000));
  const attackerX=Number(mission.depart_x),attackerY=Number(mission.depart_y),defenderX=Number(mission.target_x),defenderY=Number(mission.target_y);
  const battlePoints=calculateBattlePoints(result,attackPower,defensePower);
  const winnerPlayerId=result==="Zafer"?Number(mission.attacker_player_id):result==="Yenilgi"?Number(mission.defender_player_id):null;
  const reportBase={
    version:4,
    result,
    attackPower,
    defensePower,
    rawAttackPower:Math.round(rawAttackPower),
    rawDefensePower:Math.round(rawDefensePower),
    defenseBonus:wallBonus,
    advantageRatio:Number(ratio.toFixed(4)),
    attackerLosses,
    defenderLosses,
    survivorArmy,
    battlePoints,
    winnerPlayerId,
    attackerX:Number.isFinite(attackerX)?attackerX:null,
    attackerY:Number.isFinite(attackerY)?attackerY:null,
    defenderX:Number.isFinite(defenderX)?defenderX:null,
    defenderY:Number.isFinite(defenderY)?defenderY:null,
    attackerBreakdown,
    defenderBreakdown
  };
  const defenderSnapshot=defenders.map(u=>({
    id:Number(u.id),
    unit_type:u.unit_type,
    quantity:Number(u.quantity||0),
    level:Number(u.level||1)
  }));

  const resolvedResult=await supabase("rpc/nexora_resolve_military_mission",{
    method:"POST",
    body:JSON.stringify({
      p_player_id:Number(playerId),
      p_mission_id:Number(mission.id),
      p_defender_snapshot:defenderSnapshot,
      p_defender_losses:defenderLosses,
      p_report_base:reportBase,
      p_attack_power:attackPower,
      p_defense_power:defensePower,
      p_loot_rate:result==="Zafer"?0.10:0,
      p_battle_points:battlePoints,
      p_winner_player_id:winnerPlayerId,
      p_return_seconds:outbound
    })
  });

  if(!resolvedResult.ok){
    console.error("Atomik savaş çözümleme RPC hatası:",resolvedResult.data);
    return send(res,500,{success:false,message:"Savaş sonucu işlenemedi."});
  }

  const resolved=resolvedResult.data||{};
  if(resolved.success!==true){
    const code=String(resolved.code||"");
    const status=code==="DEFENDER_CHANGED"?409:code==="FORBIDDEN"?403:code==="MISSION_NOT_FOUND"?404:400;
    return send(res,status,{
      success:false,
      code:code||"MISSION_RESOLVE_FAILED",
      message:resolved.message||"Savaş sonucu işlenemedi."
    });
  }

  const resolvedMission=resolved.mission||mission;
  const remainingSeconds=resolvedMission.status==="returning"
    ?Math.max(0,Math.ceil((new Date(resolvedMission.arrive_at).getTime()-Date.now())/1000))
    :0;
  return send(res,200,{success:true,mission:{...resolvedMission,remainingSeconds}});
}

async function syncResearchCityResources(playerId, city, buildings, research){
  // Research must use the same row-locked production sync as the city screen.
  // Never write resource balances from an older city snapshot.
  const productionSync=await supabase("rpc/nexora_sync_city_production",{
    method:"POST",
    body:JSON.stringify({p_player_id:Number(playerId)})
  });

  if(!productionSync.ok||productionSync.data?.success===false||!productionSync.data?.city){
    console.error("Araştırma atomik üretim senkronizasyonu hatası:",productionSync.data);
    return null;
  }

  let syncedCity=productionSync.data.city;
  const populationCap=housingCapacity(buildings);
  const armyCap=armyCapacity(buildings);

  // Only non-resource capacity fields are allowed in this PATCH.
  if(
    Number(syncedCity.population_capacity)!==populationCap||
    Number(syncedCity.army_capacity)!==armyCap
  ){
    const updated=await supabase(
      "cities?id=eq."+encodeURIComponent(syncedCity.id),
      {
        method:"PATCH",
        headers:{Prefer:"return=representation"},
        body:JSON.stringify({
          population_capacity:populationCap,
          army_capacity:armyCap
        })
      }
    );
    if(updated.ok&&updated.data?.[0])syncedCity=updated.data[0];
  }

  return syncedCity;
}

async function upgradeResearch(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum bulunamadı."});
  const body=await readBody(req); const type=String(body.researchType||"").trim();
  const map={production:"production_level",combat:"combat_level",defense:"defense_level",crystal:"crystal_level",general_power:"general_power_level",unit_attack:"unit_attack_level",unit_defense:"unit_defense_level",unit_hp:"unit_hp_level",travel_speed:"travel_speed_level"};
  const column=map[type]; if(!column)return send(res,400,{success:false,message:"Geçersiz araştırma türü."});
  const base={production:{metal:500,energy:150,crystal:25},combat:{metal:700,energy:200,crystal:40},defense:{metal:600,energy:180,crystal:35},crystal:{metal:800,energy:250,crystal:60},general_power:{metal:1000,energy:300,crystal:50},unit_attack:{metal:900,energy:250,crystal:45},unit_defense:{metal:850,energy:250,crystal:45},unit_hp:{metal:950,energy:275,crystal:50},travel_speed:{metal:1200,energy:350,crystal:65}};
  const cityResult=await supabase("cities?select=*&player_id=eq."+encodeURIComponent(playerId)+"&limit=1");
  if(!cityResult.ok)return send(res,500,{success:false,message:"Koloni veritabanından alınamadı."});
  let city=cityResult.data?.[0];
  if(!city){
    const createResult=await supabase("cities",{method:"POST",headers:{Prefer:"return=representation"},body:JSON.stringify({player_id:playerId,name:"Yeni Koloni",level:1,metal:1000,energy:500,water:500,crystal:250})});
    if(!createResult.ok||!createResult.data?.[0])return send(res,500,{success:false,message:"Koloni oluşturulamadı."});
    city=createResult.data[0];
  }
  const buildingsResult=await supabase("buildings?select=*&city_id=eq."+encodeURIComponent(city.id)); const buildings=buildingsResult.ok?(buildingsResult.data||[]):[];
  const rr=await supabase("research?select=*&player_id=eq."+encodeURIComponent(playerId)+"&limit=1"); let research=rr.data?.[0];
  if(!rr.ok)return send(res,500,{success:false,message:"Araştırma verisi alınamadı."});
  if(!research)research={};
  if(research.upgrade_ready_at){research=await finalizeResearch(research);}
  city=await syncResearchCityResources(playerId,city,buildings,research);
  if(!city)return send(res,503,{success:false,message:"Koloni üretimi senkronize edilemedi."});
  if(research.upgrade_ready_at)return send(res,400,{success:false,message:"Başka bir araştırma zaten sürüyor.",finishAt:research.upgrade_ready_at});
  const level=Math.max(0,Number(research[column]||0)); if(level>=15)return send(res,400,{success:false,message:"Bu araştırma zaten 15. seviyede."});
  const mult=level+1; const cost={metal:base[type].metal*mult,energy:base[type].energy*mult,water:0,crystal:base[type].crystal*mult};
  const duration=60+level*45;
  const spend=await supabase("rpc/nexora_start_research_upgrade",{method:"POST",body:JSON.stringify({p_player_id:Number(playerId),p_city_id:Number(city.id),p_column:column,p_level:level,p_cost:cost,p_duration:duration})});
  if(!spend.ok)return send(res,500,{success:false,message:"Kaynaklar güncellenemedi."});
  if(spend.data?.success===false)return send(res,400,{success:false,message:spend.data?.message||"Yeterli kaynak yok.",cost:spend.data?.cost||cost,available:spend.data?.available});
  city=spend.data?.city;
  if(!city)return send(res,500,{success:false,message:"Kaynaklar güncellenemedi."});
  return send(res,200,{success:true,message:"🔬 Araştırma başlatıldı.",research:spend.data.research,city,finishAt:spend.data.finishAt,duration});
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

  if (
    !existingMembership.ok
  ) {
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
async function getMyAlliance(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum bulunamadı."});
  const m=await supabase("alliance_members?select=id,alliance_id,player_id,role,role_v2&player_id=eq."+encodeURIComponent(playerId)+"&limit=1");
  if(!m.ok)return send(res,500,{success:false,message:"İttifak üyeliği alınamadı."});
  if(!m.data?.[0])return send(res,200,{success:true,alliance:null,member:null,members:[],announcements:[],activity:[]});
  const allianceId=Number(m.data[0].alliance_id);
  const [a,members,announcements,activity]=await Promise.all([
    supabase("alliances?select=*&id=eq."+encodeURIComponent(allianceId)+"&limit=1"),
    supabase("alliance_members?select=player_id,role,role_v2&alliance_id=eq."+encodeURIComponent(allianceId)),
    supabase("alliance_announcements?select=id,author_player_id,message,created_at&alliance_id=eq."+encodeURIComponent(allianceId)+"&order=created_at.desc,id.desc&limit=20"),
    supabase("alliance_activity?select=id,event_type,actor_player_id,target_player_id,metadata,created_at&alliance_id=eq."+encodeURIComponent(allianceId)+"&order=created_at.desc,id.desc&limit=30")
  ]);
  if(!a.ok||!a.data?.[0])return send(res,500,{success:false,message:"İttifak bilgisi alınamadı."});
  if(!members.ok)return send(res,500,{success:false,message:"İttifak üyeleri alınamadı."});
  if(!announcements.ok)return send(res,500,{success:false,message:"İttifak duyuruları alınamadı."});
  if(!activity.ok)return send(res,500,{success:false,message:"İttifak aktivitesi alınamadı."});

  const ids=Array.from(new Set([
    ...(members.data||[]).map(x=>Number(x.player_id)),
    ...(announcements.data||[]).map(x=>Number(x.author_player_id)),
    ...(activity.data||[]).flatMap(x=>[Number(x.actor_player_id),Number(x.target_player_id)])
  ].filter(x=>Number.isInteger(x)&&x>0)));
  const pr=ids.length?await supabase("players?select=id,username&id=in.("+ids.join(",")+")"):({ok:true,data:[]});
  const names={};for(const p of pr.data||[])names[Number(p.id)]=p.username;

  const memberIds=(members.data||[]).map(x=>x.player_id).filter(Boolean).join(",");
  let alliancePower=0;
  if(memberIds){
    const cities=await supabase("cities?select=id&player_id=in.("+memberIds+")");
    const cityIds=(cities.data||[]).map(x=>x.id);
    if(cityIds.length){
      const units=await supabase("units?select=quantity,attack,defense,hp&city_id=in.("+cityIds.join(",")+")");
      for(const u of units.data||[])alliancePower+=Number(u.quantity||0)*(Number(u.attack||0)+Number(u.defense||0)+Number(u.hp||0)*0.5);
    }
  }

  const effectiveRole=x=>x?.role==="leader"?"leader":(x?.role_v2==="officer"?"officer":"member");
  const alliance={...a.data[0],member_count:(members.data||[]).length,alliance_power:Math.round(alliancePower)};
  const member={...m.data[0],effective_role:effectiveRole(m.data[0])};
  const memberList=(members.data||[]).map(x=>({
    player_id:x.player_id,
    username:names[Number(x.player_id)]||"Oyuncu",
    role:x.role,
    role_v2:x.role_v2,
    effective_role:effectiveRole(x)
  }));
  const announcementList=(announcements.data||[]).map(x=>({
    id:x.id,
    author_player_id:x.author_player_id,
    author_username:names[Number(x.author_player_id)]||"Oyuncu",
    message:x.message,
    created_at:x.created_at
  }));
  const activityList=(activity.data||[]).map(x=>({
    id:x.id,
    event_type:x.event_type,
    actor_player_id:x.actor_player_id,
    actor_username:names[Number(x.actor_player_id)]||null,
    target_player_id:x.target_player_id,
    target_username:names[Number(x.target_player_id)]||null,
    metadata:x.metadata||{},
    created_at:x.created_at
  }));
  return send(res,200,{success:true,alliance,member,members:memberList,announcements:announcementList,activity:activityList});
}
async function setAllianceMemberRole(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum bulunamadı."});
  let body; try{body=await readBody(req);}catch{return send(res,400,{success:false,message:"Geçersiz istek."});}
  const targetPlayerId=Number(body?.playerId);
  const role=String(body?.role||"").trim().toLowerCase();
  if(!Number.isInteger(targetPlayerId)||targetPlayerId<=0)return send(res,400,{success:false,message:"Geçersiz oyuncu."});
  if(!["officer","member"].includes(role))return send(res,400,{success:false,message:"Geçersiz ittifak rolü."});
  const result=await supabase("rpc/nexora_alliance_set_member_role",{method:"POST",body:JSON.stringify({p_actor_player_id:playerId,p_target_player_id:targetPlayerId,p_role:role})});
  if(!result.ok||typeof result.data?.success!=="boolean"){
    console.error("İttifak rol RPC hatası:",result.data);
    return send(res,500,{success:false,message:"İttifak rolü güncellenemedi."});
  }
  return send(res,result.data.success?200:400,result.data);
}

async function postAllianceAnnouncement(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum bulunamadı."});
  let body; try{body=await readBody(req);}catch{return send(res,400,{success:false,message:"Geçersiz istek."});}
  const message=String(body?.message||"").trim();
  if(!message||message.length>500)return send(res,400,{success:false,message:"Duyuru 1-500 karakter arasında olmalı."});
  const result=await supabase("rpc/nexora_alliance_post_announcement",{method:"POST",body:JSON.stringify({p_actor_player_id:playerId,p_message:message})});
  if(!result.ok||typeof result.data?.success!=="boolean"){
    console.error("İttifak duyuru RPC hatası:",result.data);
    return send(res,500,{success:false,message:"İttifak duyurusu yayınlanamadı."});
  }
  return send(res,result.data.success?200:400,result.data);
}

async function deleteAllianceAnnouncement(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum bulunamadı."});
  let body; try{body=await readBody(req);}catch{return send(res,400,{success:false,message:"Geçersiz istek."});}
  const announcementId=Number(body?.announcementId);
  if(!Number.isInteger(announcementId)||announcementId<=0)return send(res,400,{success:false,message:"Geçersiz duyuru."});
  const result=await supabase("rpc/nexora_alliance_delete_announcement",{method:"POST",body:JSON.stringify({p_actor_player_id:playerId,p_announcement_id:announcementId})});
  if(!result.ok||typeof result.data?.success!=="boolean"){
    console.error("İttifak duyuru silme RPC hatası:",result.data);
    return send(res,500,{success:false,message:"İttifak duyurusu silinemedi."});
  }
  return send(res,result.data.success?200:400,result.data);
}

async function getAllianceWars(req,res){
  const playerId=authPlayerId(req);
  if(playerId===null)return send(res,401,{success:false,message:"Oturum bulunamadı."});

  const result=await supabase("rpc/nexora_alliance_wars_snapshot",{
    method:"POST",
    body:JSON.stringify({p_player_id:playerId})
  });

  if(!result.ok||typeof result.data?.success!=="boolean"){
    console.error("İttifak savaşları snapshot RPC hatası:",result.data);
    return send(res,503,{success:false,message:"İttifak savaşları şu anda kullanılamıyor."});
  }

  return send(res,result.data.success?200:400,result.data);
}

async function declareAllianceWar(req,res){
  const playerId=authPlayerId(req);
  if(playerId===null)return send(res,401,{success:false,message:"Oturum bulunamadı."});

  let body;
  try{body=await readBody(req);}
  catch{return send(res,400,{success:false,message:"Geçersiz istek."});}

  const targetAllianceId=Number(body?.targetAllianceId);
  if(!Number.isInteger(targetAllianceId)||targetAllianceId<=0){
    return send(res,400,{success:false,message:"Geçersiz hedef ittifak."});
  }

  const result=await supabase("rpc/nexora_alliance_war_declare",{
    method:"POST",
    body:JSON.stringify({
      p_actor_player_id:playerId,
      p_target_alliance_id:targetAllianceId
    })
  });

  if(!result.ok||typeof result.data?.success!=="boolean"){
    console.error("İttifak savaş ilanı RPC hatası:",result.data);
    return send(res,503,{success:false,message:"Savaş çağrısı gönderilemedi."});
  }

  return send(res,result.data.success?200:400,result.data);
}

async function respondAllianceWar(req,res){
  const playerId=authPlayerId(req);
  if(playerId===null)return send(res,401,{success:false,message:"Oturum bulunamadı."});

  let body;
  try{body=await readBody(req);}
  catch{return send(res,400,{success:false,message:"Geçersiz istek."});}

  const warId=Number(body?.warId);
  const accept=body?.accept;

  if(!Number.isInteger(warId)||warId<=0||typeof accept!=="boolean"){
    return send(res,400,{success:false,message:"Geçersiz savaş yanıtı."});
  }

  const result=await supabase("rpc/nexora_alliance_war_respond",{
    method:"POST",
    body:JSON.stringify({
      p_actor_player_id:playerId,
      p_war_id:warId,
      p_accept:accept
    })
  });

  if(!result.ok||typeof result.data?.success!=="boolean"){
    console.error("İttifak savaş yanıtı RPC hatası:",result.data);
    return send(res,503,{success:false,message:"Savaş çağrısı yanıtlanamadı."});
  }

  return send(res,result.data.success?200:400,result.data);
}

async function leaveAlliance(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum bulunamadı."});
  const result=await supabase("rpc/nexora_leave_alliance",{method:"POST",body:JSON.stringify({p_player_id:playerId})});
  if(!result.ok){console.error("İttifaktan ayrılma RPC hatası:",result.data);return send(res,500,{success:false,message:"İttifaktan ayrılınamadı."});}
  const data=result.data||{};
  if(!data.success)return send(res,400,data);
  return send(res,200,data);
}

async function kickAllianceMember(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum bulunamadı."});
  const body=await readBody(req);
  const targetPlayerId=Number(body.playerId);
  if(!Number.isInteger(targetPlayerId)||targetPlayerId<=0)return send(res,400,{success:false,message:"Geçersiz oyuncu."});
  const result=await supabase("rpc/nexora_kick_alliance_member",{method:"POST",body:JSON.stringify({p_leader_player_id:playerId,p_target_player_id:targetPlayerId})});
  if(!result.ok){console.error("İttifak üyesi çıkarma RPC hatası:",result.data);return send(res,500,{success:false,message:"Oyuncu ittifaktan çıkarılamadı."});}
  const data=result.data||{};
  if(!data.success)return send(res,400,data);
  return send(res,200,data);
}
async function getAlliances(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum bulunamadı."});
  const result=await supabase("alliances?select=id,name,tag,owner_player_id,created_at&order=name.asc");
  if(!result.ok)return send(res,500,{success:false,message:"İttifaklar alınamadı."});
  const list=[];
  for(const a of result.data||[]){
    const m=await supabase("alliance_members?select=player_id&alliance_id=eq."+encodeURIComponent(a.id));
    const ids=(m.data||[]).map(x=>x.player_id).filter(Boolean);
    let power=0;
    if(ids.length){
      const c=await supabase("cities?select=id,player_id&player_id=in.("+ids.join(",")+")");
      const cityIds=(c.data||[]).map(x=>x.id);
      if(cityIds.length){const u=await supabase("units?select=quantity,attack,defense,hp&city_id=in.("+cityIds.join(",")+")");for(const x of u.data||[])power+=Number(x.quantity||0)*(Number(x.attack||0)+Number(x.defense||0)+Number(x.hp||0)*0.5);}
    }
    list.push({...a,member_count:ids.length,alliance_power:Math.round(power)});
  }
  return send(res,200,{success:true,alliances:list});
}

async function getResearch(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum bulunamadı."});
  const cityResult=await supabase("cities?select=*&player_id=eq."+encodeURIComponent(playerId)+"&limit=1");
  if(!cityResult.ok)return send(res,500,{success:false,message:"Koloni veritabanından alınamadı."});
  let city=cityResult.data?.[0];
  if(!city){
    const createResult=await supabase("cities",{method:"POST",headers:{Prefer:"return=representation"},body:JSON.stringify({player_id:playerId,name:"Yeni Koloni",level:1,metal:1000,energy:500,water:500,crystal:250})});
    if(!createResult.ok||!createResult.data?.[0])return send(res,500,{success:false,message:"Koloni oluşturulamadı."});
    city=createResult.data[0];
  }
  const buildingsResult=await supabase("buildings?select=*&city_id=eq."+encodeURIComponent(city.id));
  const buildings=buildingsResult.ok?(buildingsResult.data||[]):[];
  const result=await supabase("research?select=*&player_id=eq."+encodeURIComponent(playerId)+"&limit=1");
  if(!result.ok)return send(res,500,{success:false,message:"Araştırma verileri alınamadı."});
  let research=result.data?.[0];
  if(!research){const cr=await supabase("research",{method:"POST",headers:{Prefer:"return=representation"},body:JSON.stringify({player_id:playerId,production_level:0,combat_level:0,defense_level:0,crystal_level:0,general_power_level:0,unit_attack_level:0,unit_defense_level:0,unit_hp_level:0,travel_speed_level:0})});if(!cr.ok)return send(res,500,{success:false,message:"Araştırma kaydı oluşturulamadı."});research=cr.data[0];}
  research=await finalizeResearch(research);
  city=await syncResearchCityResources(playerId,city,buildings,research);
  if(!city)return send(res,503,{success:false,message:"Koloni üretimi senkronize edilemedi."});
  const remaining=research.upgrade_ready_at?Math.max(0,Math.ceil((new Date(research.upgrade_ready_at).getTime()-Date.now())/1000)):0;
  return send(res,200,{success:true,research,city:{metal:Number(city.metal||0),energy:Number(city.energy||0),water:Number(city.water||0),crystal:Number(city.crystal||0),metal_capacity:storageCapacity(buildings),energy_capacity:storageCapacity(buildings),water_capacity:storageCapacity(buildings),crystal_capacity:crystalStorageCapacity(buildings)},serverTime:new Date().toISOString(),remainingSeconds:remaining});
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

  const espionageResult = await supabase(
    "espionage_missions?select=id,attacker_player_id,defender_player_id,status,depart_at,arrive_at,completed_at,distance,attacker_watchtower_level,defender_watchtower_level,detected,result,created_at" +
      "&attacker_player_id=eq." +
      encodeURIComponent(playerId) +
      "&status=eq.completed&order=completed_at.desc,id.desc&limit=100"
  );

  if (!espionageResult.ok) {
    console.error(
      "Casusluk raporları alınamadı:",
      espionageResult.data
    );
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

  const reportsRaw = reportsResult.data || [];

  const playerIds = Array.from(
    new Set(
      reportsRaw
        .flatMap(function(report) {
          return [
            Number(report.attacker_player_id),
            Number(report.defender_player_id)
          ];
        })
        .filter(function(id) {
          return Number.isInteger(id) && id > 0;
        })
    )
  );

  let cityMap = {};

  if (playerIds.length) {
    const cityQuery =
      "cities?select=player_id,coordinate_x,coordinate_y&player_id=in.(" +
      playerIds.join(",") +
      ")";

    const citiesResult = await supabase(cityQuery);

    if (citiesResult.ok) {
      (citiesResult.data || []).forEach(function(city) {
        cityMap[Number(city.player_id)] = city;
      });
    }
  }

  const reports = reportsRaw.map(function(report) {
    let normalizedResult = {};

    if (
      report.result &&
      typeof report.result === "object" &&
      !Array.isArray(report.result)
    ) {
      normalizedResult = report.result;
    } else if (typeof report.result === "string") {
      try {
        const parsed = JSON.parse(report.result);

        if (
          parsed &&
          typeof parsed === "object" &&
          !Array.isArray(parsed)
        ) {
          normalizedResult = parsed;
        } else {
          normalizedResult = {
            result: String(report.result || "")
          };
        }
      } catch {
        normalizedResult = {
          result: String(report.result || "")
        };
      }
    }

    const attackerCity =
      cityMap[Number(report.attacker_player_id)] || {};

    const defenderCity =
      cityMap[Number(report.defender_player_id)] || {};

    return {
      ...report,

      result: normalizedResult,

      attacker_username:
        playerMap[report.attacker_player_id] ||
        "Bilinmeyen Oyuncu",

      defender_username:
        playerMap[report.defender_player_id] ||
        "Bilinmeyen Oyuncu",

      attacker_x:
        normalizedResult.attackerX ??
        attackerCity.coordinate_x ??
        null,

      attacker_y:
        normalizedResult.attackerY ??
        attackerCity.coordinate_y ??
        null,

      defender_x:
        normalizedResult.defenderX ??
        defenderCity.coordinate_x ??
        null,

      defender_y:
        normalizedResult.defenderY ??
        defenderCity.coordinate_y ??
        null
    };
  });

  const espionageReports = (espionageResult.ok ? (espionageResult.data || []) : []).map(function(report) {
    let normalizedResult = {};

    if (
      report.result &&
      typeof report.result === "object" &&
      !Array.isArray(report.result)
    ) {
      normalizedResult = report.result;
    } else if (typeof report.result === "string") {
      try {
        const parsed = JSON.parse(report.result);

        if (
          parsed &&
          typeof parsed === "object" &&
          !Array.isArray(parsed)
        ) {
          normalizedResult = parsed;
        }
      } catch {}
    }

    return {
      ...report,
      result: normalizedResult,
      attacker_username:
        playerMap[report.attacker_player_id] ||
        "Bilinmeyen Oyuncu",
      defender_username:
        playerMap[report.defender_player_id] ||
        "Bilinmeyen Oyuncu"
    };
  });

  return send(res, 200, {
    success: true,
    reports: reports,
    espionageReports: espionageReports
  });
}

async function upgradeBuilding(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum bulunamadı."});
  const body=await readBody(req);
  const buildingType=String(body.building||"").trim();
  const slot=body.slot==null?1:Number(body.slot);
  const costs={"Metal Madeni":{metal:500,energy:100,water:50,crystal:25},"Enerji Santrali":{metal:400,energy:50,water:50,crystal:20},"Su Arıtma":{metal:350,energy:75,water:50,crystal:20},"Kristal Madeni":{metal:600,energy:120,water:40,crystal:30},"Kışla":{metal:450,energy:100,water:50,crystal:25},"Merkez Bina":{metal:750,energy:150,water:100,crystal:50},"Depo":{metal:700,energy:120,water:60,crystal:40},"Kristal Deposu":{metal:800,energy:140,water:70,crystal:45},"Konut":{metal:500,energy:80,water:100,crystal:25},"Sur":{metal:900,energy:150,water:80,crystal:80},"Savunma Kulesi":{metal:1200,energy:220,water:100,crystal:100},"Gözcü Kulesi":{metal:1200,energy:220,water:100,crystal:100}};
  const slotTwoTypes=new Set(["Metal Madeni","Enerji Santrali","Su Arıtma","Kristal Madeni","Depo"]);
  if(!costs[buildingType])return send(res,400,{success:false,message:"Geçersiz bina."});
  if(!Number.isInteger(slot)||slot<1||slot>2)return send(res,400,{success:false,message:"Geçersiz bina yuvası."});
  if(slot===2&&!slotTwoTypes.has(buildingType))return send(res,400,{success:false,message:"Bu bina türünün ikinci kopyası olamaz."});
  const cityResult=await supabase("cities?select=*&player_id=eq."+encodeURIComponent(playerId)+"&limit=1");if(!cityResult.ok||!cityResult.data?.[0])return send(res,404,{success:false,message:"Koloni bulunamadı."});const city=cityResult.data[0];
  const allBuildings=await supabase("buildings?select=building_type,level,slot&city_id=eq."+encodeURIComponent(city.id));
  if(!allBuildings.ok)return send(res,500,{success:false,message:"Bina verileri alınamadı."});
  const prerequisiteLevels={};
  for(const b of (allBuildings.data||[])){
    prerequisiteLevels[b.building_type]=Math.max(
      Number(prerequisiteLevels[b.building_type]||0),
      Math.max(0,Number(b.level||0))
    );
  }
  if(slot===2){
    const centerLevel=Number(prerequisiteLevels["Merkez Bina"]||0);
    const requiredCenter=buildingType==="Depo"?7:5;
    if(centerLevel<requiredCenter)return send(res,400,{success:false,message:buildingType+" II için Merkez Bina seviye "+requiredCenter+" gerekli.",required:{building:"Merkez Bina",level:requiredCenter}});
  }
  const br=await supabase("buildings?select=*&city_id=eq."+encodeURIComponent(city.id)+"&building_type=eq."+encodeURIComponent(buildingType)+"&slot=eq."+encodeURIComponent(slot)+"&limit=1");if(!br.ok)return send(res,500,{success:false,message:"Bina verisi alınamadı."});
  let building=br.data?.[0]; if(building) building=await finalizeBuilding(building);
  if(building?.is_under_construction)return send(res,400,{success:false,message:"Bu bina zaten inşa ediliyor.",finishAt:building.upgrade_ready_at});
  const current=building?Math.max(0,Number(building.level||0)):0;
  const maxLevel=buildingMaxLevel(buildingType);
  const prerequisites={
    "Kristal Madeni":{"Merkez Bina":2},
    "Kristal Deposu":{"Merkez Bina":2},
    "Kışla":{"Merkez Bina":2},
    "Konut":{"Merkez Bina":2},
    "Sur":{"Merkez Bina":3},
    "Savunma Kulesi":{"Merkez Bina":5,"Sur":2},
    "Gözcü Kulesi":{"Merkez Bina":5,"Sur":2}
  };
  const reqs=prerequisites[buildingType]||{};
  for(const [reqName,reqLevel] of Object.entries(reqs)){
    if(Number(prerequisiteLevels[reqName]||0)<Number(reqLevel))return send(res,400,{success:false,message:buildingType+" için "+reqName+" seviye "+reqLevel+" gerekli.",required:{building:reqName,level:reqLevel}});
  }
  if(current>=maxLevel)return send(res,400,{success:false,message:buildingType+(slot===2?" II":"")+" maksimum seviye olan "+maxLevel+" seviyeye ulaştı."});
  const multiplier=current+1;
  const cost={metal:costs[buildingType].metal*multiplier,energy:costs[buildingType].energy*multiplier,water:costs[buildingType].water*multiplier,crystal:costs[buildingType].crystal*multiplier};
  const duration=45+current*45;
  const spend=await supabase("rpc/nexora_start_building_upgrade_slot",{method:"POST",body:JSON.stringify({p_player_id:Number(playerId),p_city_id:Number(city.id),p_type:buildingType,p_slot:slot,p_level:current,p_cost:cost,p_duration:duration})});
  if(!spend.ok)return send(res,500,{success:false,message:"Kaynaklar güncellenemedi."});
  if(spend.data?.success===false)return send(res,400,{success:false,message:spend.data?.message||"Yeterli kaynak bulunmuyor.",cost:spend.data?.cost||cost,available:spend.data?.available,nextLevel:current+1,slot});
  const spentCity=spend.data?.city;
  if(!spentCity)return send(res,500,{success:false,message:"Kaynaklar güncellenemedi."});
  const label=buildingType+(slot===2?" II":"");
  return send(res,200,{success:true,message:label+" için seviye "+(current+1)+" inşaatı başlatıldı.",city:spentCity,building:spend.data.building,finishAt:spend.data.finishAt,duration,cost,nextLevel:current+1,maxLevel,slot});
}

async function getWorldPlayers(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum gerekli."});
  const citiesResult=await supabase("cities?select=id,player_id,name,level,coordinate_x,coordinate_y"); if(!citiesResult.ok)return send(res,500,{success:false,message:"Koloniler alınamadı."});
  const playersResult=await supabase("players?select=id,username"); if(!playersResult.ok)return send(res,500,{success:false,message:"Oyuncular alınamadı."});
  const map={}; for(const p of playersResult.data||[])map[p.id]=p.username;
  const players=(citiesResult.data||[]).map(c=>{const region=regionForCoordinates(Number(c.coordinate_x||0),Number(c.coordinate_y||0));return {id:c.id,player_id:c.player_id,username:map[c.player_id]||"Oyuncu",name:c.name,level:c.level,coordinate_x:c.coordinate_x,coordinate_y:c.coordinate_y,region:region.name,region_bonus:region.bonus};});
  let sitesResult=await supabase("rpc/nexora_world_control_sites",{method:"POST",body:JSON.stringify({p_player_id:playerId})});
  if(!sitesResult.ok)sitesResult=await supabase("world_sites?select=id,site_type,name,coordinate_x,coordinate_y,reward&active=eq.true");
  return send(res,200,{success:true,players,sites:sitesResult.ok?(sitesResult.data||[]):[],regions:[
    {name:"Çöl Bölgesi",bonus:"Metal üretimi +5%"},{name:"Orman Bölgesi",bonus:"Su üretimi +5%"},{name:"Buz Bölgesi",bonus:"Enerji üretimi +5%"},{name:"Dağ Bölgesi",bonus:"Savunma +5%"},{name:"Volkanik Bölge",bonus:"Kristal üretimi +5%"},{name:"Okyanus",bonus:"Seyahat süresi -5%"}
  ]});
}

async function claimWorldSite(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum gerekli."});
  let body; try{body=await readBody(req);}catch{return send(res,400,{success:false,message:"Geçersiz istek."});}
  const siteId=body?.siteId;
  if(typeof siteId!=="number"||!Number.isSafeInteger(siteId)||siteId<=0)return send(res,400,{success:false,message:"Geçersiz dünya noktası."});
  const result=await supabase("rpc/nexora_claim_world_site",{method:"POST",body:JSON.stringify({p_player_id:playerId,p_site_id:siteId})});
  if(!result.ok||typeof result.data?.success!=="boolean")return send(res,503,{success:false,message:"Nokta kontrol işlemi şu anda kullanılamıyor."});
  return send(res,result.data.success?200:400,result.data);
}

async function getGameObjectives(req,res){
  const playerId=authPlayerId(req);
  if(playerId===null)return send(res,401,{success:false,message:"Oturum gerekli."});

  const result=await supabase("rpc/nexora_refresh_achievements",{
    method:"POST",
    body:JSON.stringify({p_player_id:playerId})
  });

  if(!result.ok||typeof result.data?.success!=="boolean"){
    return send(res,503,{success:false,message:"Görev ve başarım sistemi şu anda kullanılamıyor."});
  }

  return send(res,result.data.success?200:400,result.data);
}

async function claimGameMission(req,res){
  const playerId=authPlayerId(req);
  if(playerId===null)return send(res,401,{success:false,message:"Oturum gerekli."});

  let body;
  try{body=await readBody(req);}
  catch{return send(res,400,{success:false,message:"Geçersiz istek."});}

  const missionId=String(body?.missionId||"").trim();
  if(!missionId||missionId.length>100||!/^[a-z0-9_-]+$/i.test(missionId)){
    return send(res,400,{success:false,message:"Geçersiz görev."});
  }

  const result=await supabase("rpc/nexora_claim_mission",{
    method:"POST",
    body:JSON.stringify({p_player_id:playerId,p_mission_id:missionId})
  });

  if(!result.ok||typeof result.data?.success!=="boolean"){
    return send(res,503,{success:false,message:"Görev ödülü işlemi şu anda kullanılamıyor."});
  }

  return send(res,result.data.success?200:400,result.data);
}

async function exploreWorld(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum gerekli."});
  const body=await readBody(req);
  const siteId=Number(body.siteId);
  if(!Number.isInteger(siteId)||siteId<=0)return send(res,400,{success:false,message:"Geçersiz keşif noktası."});

  const [cityR,siteR,researchR]=await Promise.all([
    supabase("cities?select=id,coordinate_x,coordinate_y&player_id=eq."+encodeURIComponent(playerId)+"&limit=1"),
    supabase("world_sites?select=id,site_type,name,coordinate_x,coordinate_y,active&id=eq."+encodeURIComponent(siteId)+"&limit=1"),
    supabase("research?select=travel_speed_level&player_id=eq."+encodeURIComponent(playerId)+"&limit=1")
  ]);
  if(!cityR.ok||!cityR.data?.[0])return send(res,404,{success:false,message:"Koloni bulunamadı."});
  if(!siteR.ok||!siteR.data?.[0]||siteR.data[0].active===false)return send(res,404,{success:false,message:"Keşif noktası bulunamadı veya aktif değil."});

  const city=cityR.data[0], site=siteR.data[0];

  const distance=Math.sqrt(Math.pow(Number(site.coordinate_x||0)-Number(city.coordinate_x||0),2)+Math.pow(Number(site.coordinate_y||0)-Number(city.coordinate_y||0),2));
  const research=researchR.ok&&researchR.data?.[0]?researchR.data[0]:{};
  const speedResearch=Math.max(0.25,1-Number(research.travel_speed_level||0)*0.05);
  const scoutSpeed=100;
  const travelSeconds=Math.max(10,Math.round(Math.max(1,distance)*120/scoutSpeed*speedResearch));

  const started=await supabase("rpc/nexora_start_world_exploration",{
    method:"POST",
    body:JSON.stringify({p_player_id:playerId,p_site_id:siteId,p_travel_seconds:travelSeconds,p_distance:Number(distance.toFixed(2))})
  });
  if(!started.ok){console.error("Keşif başlatma RPC hatası:",started.data);return send(res,500,{success:false,message:"Keşif görevi başlatılamadı."});}
  const result=started.data||{};
  if(!result.success&&result.code==="ACTIVE_EXPLORATION"&&Number.isInteger(Number(result.missionId))){
    const active=await supabase("rpc/nexora_resolve_world_exploration",{
      method:"POST",
      body:JSON.stringify({p_player_id:playerId,p_mission_id:Number(result.missionId)})
    });
    if(active.ok&&active.data?.success&&active.data.mission){
      const mission=active.data.mission;
      return send(res,200,{success:true,message:"Aktif keşif görevin devam ediyor.",mission:{...mission,travelSeconds:Number(mission.remainingSeconds||0)}});
    }
  }
  if(!result.success)return send(res,result.code==="SITE_NOT_FOUND"?404:400,result);
  return send(res,200,result);
}

async function getWorldExploration(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum gerekli."});
  const missionId=Number(req.query.id);
  if(!Number.isInteger(missionId)||missionId<=0)return send(res,400,{success:false,message:"Geçersiz keşif görevi."});
  const resolved=await supabase("rpc/nexora_resolve_world_exploration",{
    method:"POST",
    body:JSON.stringify({p_player_id:playerId,p_mission_id:missionId})
  });
  if(!resolved.ok){console.error("Keşif sonuçlandırma RPC hatası:",resolved.data);return send(res,500,{success:false,message:"Keşif durumu alınamadı."});}
  const result=resolved.data||{};
  if(!result.success)return send(res,result.code==="MISSION_NOT_FOUND"?404:400,result);
  return send(res,200,result);
}


async function startEspionage(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum gerekli."});
  let body; try{body=await readBody(req);}catch{return send(res,400,{success:false,message:"Geçersiz istek."});}
  const targetPlayerId=Number(body?.targetPlayerId);
  if(!Number.isSafeInteger(targetPlayerId)||targetPlayerId<=0)return send(res,400,{success:false,message:"Geçersiz casusluk hedefi."});
  if(targetPlayerId===Number(playerId))return send(res,400,{success:false,message:"Kendi kolonine casus gönderemezsin."});

  const [attackerCityR,targetCityR,researchR]=await Promise.all([
    supabase("cities?select=id,coordinate_x,coordinate_y&player_id=eq."+encodeURIComponent(playerId)+"&limit=1"),
    supabase("cities?select=id,coordinate_x,coordinate_y&player_id=eq."+encodeURIComponent(targetPlayerId)+"&limit=1"),
    supabase("research?select=travel_speed_level&player_id=eq."+encodeURIComponent(playerId)+"&limit=1")
  ]);

  if(!attackerCityR.ok)return send(res,503,{success:false,message:"Koloni bilgisi alınamadı."});
  if(!targetCityR.ok)return send(res,503,{success:false,message:"Hedef koloni bilgisi alınamadı."});
  if(!attackerCityR.data?.[0])return send(res,404,{success:false,message:"Koloni bulunamadı."});
  if(!targetCityR.data?.[0])return send(res,404,{success:false,message:"Hedef koloni bulunamadı."});

  const attackerCity=attackerCityR.data[0];
  const targetCity=targetCityR.data[0];
  const distance=Math.sqrt(
    Math.pow(Number(targetCity.coordinate_x||0)-Number(attackerCity.coordinate_x||0),2)+
    Math.pow(Number(targetCity.coordinate_y||0)-Number(attackerCity.coordinate_y||0),2)
  );
  const research=researchR.ok&&researchR.data?.[0]?researchR.data[0]:{};
  const speedResearch=Math.max(0.25,1-Number(research.travel_speed_level||0)*0.05);
  const travelSeconds=Math.max(5,Math.ceil((Math.max(1,distance)/2)*speedResearch));

  const started=await supabase("rpc/nexora_start_espionage",{
    method:"POST",
    body:JSON.stringify({
      p_attacker_player_id:Number(playerId),
      p_defender_player_id:Number(targetPlayerId),
      p_travel_seconds:travelSeconds,
      p_distance:Number(distance.toFixed(2))
    })
  });

  if(!started.ok){
    console.error("Casusluk başlatma RPC hatası:",started.data);
    return send(res,503,{success:false,message:"Casusluk görevi şu anda başlatılamıyor."});
  }

  const result=started.data||{};
  if(result.success!==true){
    const code=String(result.code||"");
    const status=code==="ACTIVE_ESPIONAGE"?409:(code==="CITY_NOT_FOUND"||code==="TARGET_CITY_NOT_FOUND")?404:400;
    return send(res,status,{
      ...result,
      success:false,
      message:result.message||"Casusluk görevi başlatılamadı."
    });
  }

  return send(res,200,result);
}

async function getEspionageStatus(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum gerekli."});
  const missionId=Number(req.query.id);
  if(!Number.isSafeInteger(missionId)||missionId<=0)return send(res,400,{success:false,message:"Geçersiz casusluk görevi."});

  const resolved=await supabase("rpc/nexora_resolve_espionage",{
    method:"POST",
    body:JSON.stringify({p_player_id:Number(playerId),p_mission_id:missionId})
  });

  if(!resolved.ok){
    console.error("Casusluk sonuçlandırma RPC hatası:",resolved.data);
    return send(res,503,{success:false,message:"Casusluk durumu şu anda alınamıyor."});
  }

  const result=resolved.data||{};
  if(result.success!==true){
    const status=String(result.code||"")==="MISSION_NOT_FOUND"?404:400;
    return send(res,status,result);
  }

  return send(res,200,result);
}


async function getMilitaryMissions(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum gerekli."});
  const r=await supabase("military_missions?select=*&or=(attacker_player_id.eq."+encodeURIComponent(playerId)+",defender_player_id.eq."+encodeURIComponent(playerId)+")&order=depart_at.desc&limit=20");
  if(!r.ok)return send(res,500,{success:false,message:"Seferler alınamadı."});
  return send(res,200,{success:true,missions:r.data||[]});
}

async function getRankings(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum gerekli."});
  const [playersR,citiesR,buildingsR,unitsR,reportsR,researchR]=await Promise.all([
    supabase("players?select=id,username"),
    supabase("cities?select=id,player_id,level"),
    supabase("buildings?select=city_id,level"),
    supabase("units?select=city_id,quantity,attack,defense,hp"),
    supabase("battle_reports?select=attacker_player_id,defender_player_id,result,battle_points,winner_player_id"),
    supabase("research?select=player_id,production_level,combat_level,defense_level,crystal_level,general_power_level,unit_attack_level,unit_defense_level,unit_hp_level,travel_speed_level")
  ]);
  const cityByPlayer={}; for(const c of citiesR.data||[])cityByPlayer[c.player_id]=c;
  const score={}; for(const p of playersR.data||[])score[p.id]={player_id:p.id,username:p.username,colony_level:Number(cityByPlayer[p.id]?.level||1),army_power:0,battle_points:0,wins:0,losses:0,draws:0,research_level:0,buildings_level:0,score:0};
  const cityPlayer={}; for(const c of citiesR.data||[])cityPlayer[c.id]=c.player_id;
  for(const b of buildingsR.data||[]){const pid=cityPlayer[b.city_id];if(score[pid])score[pid].buildings_level+=Number(b.level||0);}
  for(const u of unitsR.data||[]){const pid=cityPlayer[u.city_id];if(score[pid])score[pid].army_power+=Number(u.quantity||0)*(Number(u.attack||0)+Number(u.defense||0)+Number(u.hp||0)*0.5);}
  for(const r of researchR.data||[]){if(score[r.player_id])score[r.player_id].research_level+=Object.keys(r).filter(k=>k.endsWith('_level')).reduce((s,k)=>s+Number(r[k]||0),0);}
  for(const r of reportsR.data||[]){
    let raw=r.result;
    if(typeof raw==='string'){
      try{
        const parsed=JSON.parse(raw);
        if(parsed&&typeof parsed==='object'&&!Array.isArray(parsed))raw=parsed;
      }catch{}
    }
    const result=raw&&typeof raw==='object'?String(raw.result||''):String(raw||'');
    const attackerId=Number(r.attacker_player_id);
    const defenderId=Number(r.defender_player_id);
    const points=Number(r.battle_points ?? (raw&&typeof raw==='object'?raw.battlePoints:0))||0;
    let winner=Number(r.winner_player_id ?? (raw&&typeof raw==='object'?raw.winnerPlayerId:0))||0;
    if(!winner){
      if(result==='Zafer')winner=attackerId;
      else if(result==='Yenilgi')winner=defenderId;
    }
    if(winner&&score[winner])score[winner].battle_points+=points;
    if(result==='Beraberlik'){
      if(score[attackerId])score[attackerId].draws+=1;
      if(score[defenderId])score[defenderId].draws+=1;
      continue;
    }
    if(winner){
      if(score[winner])score[winner].wins+=1;
      const loser=winner===attackerId?defenderId:winner===defenderId?attackerId:0;
      if(loser&&score[loser])score[loser].losses+=1;
    }
  }
  for(const x of Object.values(score))x.score=Math.round(x.colony_level*100+x.army_power+x.battle_points+x.research_level*30+x.buildings_level*20+x.wins*25);
  const rankings=Object.values(score).sort((a,b)=>b.score-a.score||b.battle_points-a.battle_points||b.army_power-a.army_power||b.wins-a.wins||a.username.localeCompare(b.username,'tr')).map((x,i)=>({...x,rank:i+1,is_me:x.player_id===playerId}));
  const me=rankings.find(x=>x.player_id===playerId)||null;
  return send(res,200,{success:true,rankings,me});
}


const TRADE_RESOURCES = new Set(["metal","energy","water","crystal"]);
const TRADE_MIN_AMOUNT = 10;
const TRADE_MAX_AMOUNT = 100000000;

function normalizeTradeResource(value){
  const resource=String(value||"").trim().toLowerCase();
  return TRADE_RESOURCES.has(resource) ? resource : null;
}

async function getTradeCity(playerId){
  const r=await supabase("cities?select=*&player_id=eq."+encodeURIComponent(playerId)+"&limit=1");
  if(!r.ok||!r.data?.[0])return {error:"Koloni bulunamadı."};
  return {city:r.data[0]};
}

async function syncTradePlayer(playerId){
  const pid=Number(playerId);
  const due=await supabase("rpc/nexora_trade_sync_player",{
    method:"POST",
    body:JSON.stringify({p_player_id:pid})
  });
  if(!due.ok||due.data?.success===false)return due;

  const ids=Array.isArray(due.data?.transactionIds)
    ? due.data.transactionIds.map(Number).filter(x=>Number.isSafeInteger(x)&&x>0)
    : [];

  let checked=0,delivered=0,blocked=0,failed=0;

  // 015 migration deliberately returns only IDs here. Each finalize call is a
  // separate PostgREST RPC/DB transaction, so city/transaction locks are not
  // accumulated across a batch.
  for(const transactionId of ids){
    const finalized=await supabase("rpc/nexora_trade_finalize_transaction",{
      method:"POST",
      body:JSON.stringify({p_transaction_id:transactionId})
    });

    checked++;

    if(!finalized.ok||finalized.data?.success===false){
      failed++;
      console.error("Trade teslimat finalizer hatası:",transactionId,finalized.data);
      continue;
    }

    if(finalized.data?.status==="delivered")delivered++;
    else if(finalized.data?.status==="blocked")blocked++;
  }

  const after=await supabase("rpc/nexora_trade_sync_player",{
    method:"POST",
    body:JSON.stringify({p_player_id:pid})
  });

  if(!after.ok||after.data?.success===false){
    return {
      ok:true,
      status:200,
      data:{
        ...due.data,
        checked,
        delivered,
        blocked,
        failed
      }
    };
  }

  return {
    ok:true,
    status:200,
    data:{
      ...after.data,
      checked,
      delivered,
      blocked,
      failed
    }
  };
}

async function getTradeOffers(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum gerekli."});

  const sync=await syncTradePlayer(playerId);
  if(!sync.ok||sync.data?.success===false){
    console.error("Trade V2 sync hatası:",sync.data);
    return send(res,503,{success:false,message:"Ticaret sistemi şu anda kullanılamıyor."});
  }

  const serverTime=sync.data?.serverTime||new Date().toISOString();
  const serverNow=new Date(serverTime).getTime();
  const serverIso=Number.isFinite(serverNow)?new Date(serverNow).toISOString():new Date().toISOString();
  const select="id,creator_player_id,give_resource,give_amount,want_resource,want_amount,status,expires_at,created_at,accepted_by_player_id,accepted_at";

  // Query only currently-open market offers from the database. Do not let the
  // last-100 rows of all statuses hide older valid open offers.
  const market=await supabase(
    "trade_offers?select="+select+
    "&status=eq.open&escrow_refunded_amount=eq.0"+
    "&expires_at=gt."+encodeURIComponent(serverIso)+
    "&order=created_at.desc&limit=100"
  );
  if(!market.ok)return send(res,500,{success:false,message:"Ticaret teklifleri alınamadı."});

  // Own open offers are fetched independently so an expired offer waiting for
  // escrow refund can never disappear behind the public market limit.
  const own=await supabase(
    "trade_offers?select="+select+
    "&creator_player_id=eq."+encodeURIComponent(playerId)+
    "&status=eq.open"+
    "&order=created_at.desc"
  );
  if(!own.ok)return send(res,500,{success:false,message:"Kendi ticaret tekliflerin alınamadı."});

  const merged=new Map();
  for(const offer of [...(market.data||[]),...(own.data||[])])merged.set(Number(offer.id),offer);
  const offers=[...merged.values()].sort((a,b)=>
    new Date(b.created_at||0).getTime()-new Date(a.created_at||0).getTime()
  );

  const ids=[...new Set(offers.map(x=>Number(x.creator_player_id)).filter(Boolean))];
  const names={};
  if(ids.length){
    const pr=await supabase("players?select=id,username&id=in.("+ids.join(",")+")");
    for(const p of (pr.data||[]))names[p.id]=p.username;
  }

  return send(res,200,{
    success:true,
    playerId,
    offers:offers.map(x=>({...x,creator_username:names[x.creator_player_id]||"Oyuncu"})),
    serverTime,
    config:sync.data?.config||{},
    delivery: {
      checked:Number(sync.data?.checked||0),
      delivered:Number(sync.data?.delivered||0),
      blocked:Number(sync.data?.blocked||0),
      pending:Number(sync.data?.pending||0)
    }
  });
}

async function createTradeOffer(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum gerekli."});
  const body=await readBody(req);
  const giveResource=normalizeTradeResource(body.giveResource);
  const wantResource=normalizeTradeResource(body.wantResource);
  const giveAmount=Number(body.giveAmount);
  const wantAmount=Number(body.wantAmount);
  const hours=body.durationHours==null?24:Number(body.durationHours);

  if(!giveResource||!wantResource||giveResource===wantResource)return send(res,400,{success:false,message:"Geçerli ve farklı iki kaynak seçmelisin."});
  if(
    !Number.isSafeInteger(giveAmount)||!Number.isSafeInteger(wantAmount)||
    giveAmount<TRADE_MIN_AMOUNT||wantAmount<TRADE_MIN_AMOUNT||
    giveAmount>TRADE_MAX_AMOUNT||wantAmount>TRADE_MAX_AMOUNT
  )return send(res,400,{success:false,message:"Ticaret miktarı 10 ile 100000000 arasında tam sayı olmalı."});
  if(!Number.isSafeInteger(hours)||hours<1||hours>72){
    return send(res,400,{success:false,message:"Teklif süresi 1 ile 72 saat arasında tam sayı olmalı."});
  }

  const rpc=await supabase("rpc/create_trade_offer",{
    method:"POST",
    body:JSON.stringify({
      p_player_id:Number(playerId),
      p_give_resource:giveResource,
      p_give_amount:giveAmount,
      p_want_resource:wantResource,
      p_want_amount:wantAmount,
      p_expires_at:new Date(Date.now()+hours*3600000).toISOString()
    })
  });

  if(!rpc.ok)return send(res,rpc.status>=400&&rpc.status<500?400:500,{
    success:false,
    message:rpc.data?.message||"Ticaret teklifi oluşturulamadı."
  });

  const data=rpc.data||{};
  return send(res,200,{
    ...data,
    success:true,
    message:data.message||"🤝 Ticaret teklifi oluşturuldu.",
    offer:data.offer||null,
    serverTime:new Date().toISOString()
  });
}

async function acceptTradeOffer(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum gerekli."});
  const body=await readBody(req);
  const offerId=Number(body.offerId);
  if(!Number.isSafeInteger(offerId)||offerId<=0){
    return send(res,400,{success:false,message:"Geçerli teklif seçilmedi."});
  }

  const rpc=await supabase("rpc/accept_trade_offer",{
    method:"POST",
    body:JSON.stringify({
      p_offer_id:offerId,
      p_acceptor_player_id:Number(playerId)
    })
  });

  if(!rpc.ok)return send(res,rpc.status>=400&&rpc.status<500?400:500,{
    success:false,
    message:rpc.data?.message||"Ticaret gerçekleştirilemedi."
  });

  const data=rpc.data||{};
  return send(res,200,{
    ...data,
    success:true,
    message:data.message||"🚚 Ticaret kabul edildi. Kaynaklar teslimata çıktı.",
    transaction:data.transaction||null,
    remainingSeconds:Number(data.remainingSeconds||data.transaction?.delivery_seconds||0),
    serverTime:data.serverTime||new Date().toISOString()
  });
}

async function cancelTradeOffer(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum gerekli."});
  const body=await readBody(req);
  const offerId=Number(body.offerId);
  if(!Number.isSafeInteger(offerId)||offerId<=0){
    return send(res,400,{success:false,message:"Geçerli teklif seçilmedi."});
  }

  const rpc=await supabase("rpc/cancel_trade_offer",{
    method:"POST",
    body:JSON.stringify({
      p_offer_id:offerId,
      p_player_id:Number(playerId)
    })
  });

  if(!rpc.ok)return send(res,rpc.status>=400&&rpc.status<500?400:500,{
    success:false,
    message:rpc.data?.message||"Ticaret teklifi iptal edilemedi."
  });

  const data=rpc.data||{};
  return send(res,200,{
    ...data,
    success:true,
    message:data.message||"↩️ Teklif kapatıldı ve kaynak iade edildi.",
    serverTime:new Date().toISOString()
  });
}

async function getTradeHistory(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum gerekli."});

  const sync=await syncTradePlayer(playerId);
  if(!sync.ok||sync.data?.success===false){
    console.error("Trade V2 history sync hatası:",sync.data);
    return send(res,503,{success:false,message:"Ticaret geçmişi şu anda kullanılamıyor."});
  }

  const r=await supabase(
    "trade_transactions?select=id,offer_id,seller_player_id,buyer_player_id,give_resource,give_amount,want_resource,want_amount,status,tax_rate,seller_tax_amount,buyer_tax_amount,seller_receive_amount,buyer_receive_amount,distance,delivery_seconds,delivery_at,delivered_at,delivery_block_reason,created_at"+
    "&or=(seller_player_id.eq."+encodeURIComponent(playerId)+",buyer_player_id.eq."+encodeURIComponent(playerId)+")"+
    "&order=created_at.desc&limit=50"
  );
  if(!r.ok)return send(res,500,{success:false,message:"Ticaret geçmişi alınamadı."});

  const history=r.data||[];
  const ids=[...new Set(history.flatMap(x=>[
    Number(x.seller_player_id),
    Number(x.buyer_player_id)
  ]).filter(Boolean))];

  const names={};
  if(ids.length){
    const pr=await supabase("players?select=id,username&id=in.("+ids.join(",")+")");
    for(const p of (pr.data||[]))names[Number(p.id)]=p.username;
  }

  return send(res,200,{
    success:true,
    playerId,
    history:history.map(x=>({
      ...x,
      seller_username:names[Number(x.seller_player_id)]||"Oyuncu",
      buyer_username:names[Number(x.buyer_player_id)]||"Oyuncu"
    })),
    serverTime:sync.data?.serverTime||new Date().toISOString(),
    config:sync.data?.config||{},
    delivery: {
      checked:Number(sync.data?.checked||0),
      delivered:Number(sync.data?.delivered||0),
      blocked:Number(sync.data?.blocked||0),
      pending:Number(sync.data?.pending||0)
    }
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
if (action === "explore") {
  return await exploreWorld(req, res);
}
if (action === "claimworldsite") {
  return await claimWorldSite(req, res);
}
if (action === "gameobjectives") {
  return await getGameObjectives(req, res);
}
if (action === "claimgamemission") {
  return await claimGameMission(req, res);
}
if (action === "explorestatus") {
  return await getWorldExploration(req, res);
}
if (action === "spy") {
  return await startEspionage(req, res);
}
if (action === "spystatus") {
  return await getEspionageStatus(req, res);
}
if (action === "move") {
  return await moveColony(req, res);
}
if (action === "upgrade") {
  return await upgradeBuilding(req, res);
}
    if (action === "army") {
  return await produceArmy(req, res);
}
    if (action === "upgradeunit") {
  return await upgradeUnit(req, res);
}
    if (action === "mission") {
  return await createMilitaryMission(req, res);
}
    if (action === "missionstatus") {
  return await getMilitaryMission(req, res);
}

    if (action === "reports") {
  return await getBattleReports(req, res);
}
    if (action === "rankings") {
      return await getRankings(req, res);
    }
    if (action === "missions") {
      return await getMilitaryMissions(req, res);
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
  if (action === "myalliance") {
      return await getMyAlliance(req, res);
    }
    if (action === "alliancewars") {
      return await getAllianceWars(req, res);
    }
    if (action === "declarealliancewar") {
      return await declareAllianceWar(req, res);
    }
    if (action === "respondalliancewar") {
      return await respondAllianceWar(req, res);
    }
    if (action === "setalliancerole") {
      return await setAllianceMemberRole(req, res);
    }
    if (action === "postallianceannouncement") {
      return await postAllianceAnnouncement(req, res);
    }
    if (action === "deleteallianceannouncement") {
      return await deleteAllianceAnnouncement(req, res);
    }
    if (action === "leavealliance") {
      return await leaveAlliance(req, res);
    }
    if (action === "kickalliance") {
      return await kickAllianceMember(req, res);
    }

    if (action === "upgraderesearch") {
  return await upgradeResearch(req, res);
}
    if (action === "tradeoffers") {
  return await getTradeOffers(req, res);
}
    if (action === "createtrade") {
  return await createTradeOffer(req, res);
}
    if (action === "accepttrade") {
  return await acceptTradeOffer(req, res);
}
    if (action === "canceltrade") {
  return await cancelTradeOffer(req, res);
}
    if (action === "tradehistory") {
  return await getTradeHistory(req, res);
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





