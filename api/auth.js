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

function buildingLevel(buildings, name) {
  const b = (buildings || []).find(x => x.building_type === name);
  return b ? Math.max(0, Number(b.level) || 0) : 0;
}

function storageCapacity(buildings) {
  const level = buildingLevel(buildings, "Depo");
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
    "Savunma Kulesi": 20
  };
  return max[name] || 30;
}

function defenseBonus(buildings) {
  const wall = buildingLevel(buildings, "Sur");
  const tower = buildingLevel(buildings, "Savunma Kulesi");
  return 1 + wall * 0.05 + tower * 0.08;
}

function totalPopulation(units, queue) {
  let total = 0;
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
  const qResult = await supabase(
    "unit_production_queue?select=*&player_id=eq." + encodeURIComponent(playerId) +
      "&city_id=eq." + encodeURIComponent(cityId) + "&status=eq.training&order=finish_at.asc"
  );
  if (!qResult.ok) return { ok: false, queue: [] };
  const now = Date.now();
  const queue = qResult.data || [];
  for (const item of queue) {
    if (new Date(item.finish_at).getTime() > now) continue;
    const unitType = item.unit_type;
    const unitLevelResult = await supabase(
      "unit_levels?select=*&unit_type=eq." + encodeURIComponent(unitType) + "&level=eq.1&limit=1"
    );
    const stats = unitLevelResult.ok && unitLevelResult.data?.[0] ? unitLevelResult.data[0] : {};
    const unitResult = await supabase(
      "units?select=*&city_id=eq." + encodeURIComponent(cityId) + "&unit_type=eq." + encodeURIComponent(unitType) + "&limit=1"
    );
    if (unitResult.ok && unitResult.data?.[0]) {
      const u = unitResult.data[0];
      await supabase("units?id=eq." + encodeURIComponent(u.id), {
        method: "PATCH", headers: { Prefer: "return=minimal" },
        body: JSON.stringify({ quantity: Number(u.quantity || 0) + Number(item.quantity || 0) })
      });
    } else {
      await supabase("units", {
        method: "POST", headers: { Prefer: "return=minimal" },
        body: JSON.stringify({
          city_id: cityId, unit_type: unitType, quantity: Number(item.quantity || 0),
          level: 1, attack: Number(stats.attack || 0), defense: Number(stats.defense || 0),
          hp: Number(stats.hp || 0), speed: Number(stats.speed || 100),
          population_cost: Number((UNIT_CONFIG[unitType] || {}).population || 1)
        })
      });
    }
    await supabase("unit_production_queue?id=eq." + encodeURIComponent(item.id) + "&status=eq.training", {
      method: "PATCH", headers: { Prefer: "return=minimal" },
      body: JSON.stringify({ status: "completed" })
    });
  }
  const finalResult = await supabase(
    "unit_production_queue?select=*&player_id=eq." + encodeURIComponent(playerId) +
      "&city_id=eq." + encodeURIComponent(cityId) + "&status=eq.training&order=finish_at.asc"
  );
  return { ok: finalResult.ok, queue: finalResult.data || [] };
}

async function finalizeBuilding(building) {
  if (!building || !building.is_under_construction || !building.upgrade_ready_at) return building;
  if (new Date(building.upgrade_ready_at).getTime() > Date.now()) return building;
  const updated = await supabase("buildings?id=eq." + encodeURIComponent(building.id) + "&is_under_construction=eq.true", {
    method: "PATCH", headers: { Prefer: "return=representation" },
    body: JSON.stringify({ level: Number(building.level || 1) + 1, is_under_construction: false, upgrade_ready_at: null })
  });
  return updated.ok && updated.data?.[0] ? updated.data[0] : building;
}

async function finalizeResearch(research) {
  if (!research || !research.upgrade_ready_at) return research;
  if (new Date(research.upgrade_ready_at).getTime() > Date.now()) return research;
  const column = research.pending_column;
  if (!column) return research;
  const updated = await supabase("research?id=eq." + encodeURIComponent(research.id), {
    method: "PATCH", headers: { Prefer: "return=representation" },
    body: JSON.stringify({ [column]: Number(research[column] || 0) + 1, upgrade_ready_at: null, pending_column: null })
  });
  return updated.ok && updated.data?.[0] ? updated.data[0] : research;
}

function capResource(value, cap) { return Math.max(0, Math.min(Number(value || 0), cap)); }

async function getCity(req, res) {
  const playerId = authPlayerId(req);
  if (playerId === null) return send(res, 401, { success: false, message: "Oturum bulunamadı." });

  const result = await supabase("cities?select=*&player_id=eq." + encodeURIComponent(playerId) + "&limit=1");
  if (!result.ok) return send(res, 500, { success: false, message: "Koloni veritabanından alınamadı." });

  if (!result.data?.[0]) {
    const createResult = await supabase("cities", { method: "POST", headers: { Prefer: "return=representation" }, body: JSON.stringify({
      player_id: playerId, name: "Yeni Koloni", level: 1, metal: 1000, energy: 500, water: 500, crystal: 250
    }) });
    if (!createResult.ok) return send(res, 500, { success: false, message: "Koloni oluşturulamadı." });
    return send(res, 200, { success: true, city: createResult.data[0], buildings: [], units: [], productionQueue: [] });
  }

  let city = result.data[0];
  const buildingsResult = await supabase("buildings?select=*&city_id=eq." + encodeURIComponent(city.id) + "&order=building_type.asc");
  if (!buildingsResult.ok) return send(res, 500, { success: false, message: "Bina verileri alınamadı." });
  let buildings = [];
  for (const b of (buildingsResult.data || [])) buildings.push(await finalizeBuilding(b));

  const production = await syncProductionQueue(playerId, city.id);
  if (!production.ok) return send(res, 500, { success: false, message: "Üretim kuyruğu alınamadı." });

  const unitsResult = await supabase("units?select=*&city_id=eq." + encodeURIComponent(city.id));
  if (!unitsResult.ok) return send(res, 500, { success: false, message: "Ordu verileri alınamadı." });
  const units = unitsResult.data || [];

  const now = Date.now();
  const lastProduction = new Date(city.last_production_at || city.updated_at || now).getTime();
  const elapsedMinutes = Math.max(0, Math.floor((now - lastProduction) / 60000));
  const researchResult = await supabase("research?select=production_level,crystal_level&player_id=eq." + encodeURIComponent(playerId) + "&limit=1");
  const research = researchResult.ok && researchResult.data?.[0] ? researchResult.data[0] : {};
  const prodMultiplier = 1 + Number(research.production_level || 0) * 0.10;
  const crystalMultiplier = 1 + Number(research.crystal_level || 0) * 0.08;
  const metalRate = buildingLevel(buildings, "Metal Madeni") * 10 * prodMultiplier;
  const energyRate = buildingLevel(buildings, "Enerji Santrali") * 10 * prodMultiplier;
  const waterRate = buildingLevel(buildings, "Su Arıtma") * 10 * prodMultiplier;
  const crystalRate = buildingLevel(buildings, "Kristal Madeni") * 5 * crystalMultiplier;
  const resourceCap = storageCapacity(buildings);
  const crystalCap = crystalStorageCapacity(buildings);
  if (elapsedMinutes > 0) {
    city.metal = capResource(Number(city.metal) + metalRate * elapsedMinutes, resourceCap);
    city.energy = capResource(Number(city.energy) + energyRate * elapsedMinutes, resourceCap);
    city.water = capResource(Number(city.water) + waterRate * elapsedMinutes, resourceCap);
    city.crystal = capResource(Number(city.crystal) + crystalRate * elapsedMinutes, crystalCap);
    const updated = await supabase("cities?id=eq." + encodeURIComponent(city.id), {
      method: "PATCH", headers: { Prefer: "return=representation" },
      body: JSON.stringify({ metal: city.metal, energy: city.energy, water: city.water, crystal: city.crystal, metal_capacity: resourceCap, energy_capacity: resourceCap, water_capacity: resourceCap, crystal_capacity: crystalCap, last_production_at: new Date().toISOString(), population_capacity: housingCapacity(buildings), army_capacity: armyCapacity(buildings), population: totalPopulation(units, production.queue), updated_at: new Date().toISOString() })
    });
    if (updated.ok && updated.data?.[0]) city = updated.data[0];
  } else if (Number(city.metal_capacity) !== resourceCap || Number(city.energy_capacity) !== resourceCap || Number(city.water_capacity) !== resourceCap || Number(city.crystal_capacity) !== crystalCap || Number(city.population_capacity) !== housingCapacity(buildings) || Number(city.army_capacity) !== armyCapacity(buildings)) {
    const updated = await supabase("cities?id=eq." + encodeURIComponent(city.id), {
      method: "PATCH", headers: { Prefer: "return=representation" },
      body: JSON.stringify({ metal_capacity: resourceCap, energy_capacity: resourceCap, water_capacity: resourceCap, crystal_capacity: crystalCap, population_capacity: housingCapacity(buildings), army_capacity: armyCapacity(buildings) })
    });
    if (updated.ok && updated.data?.[0]) city = updated.data[0];
  }

  const population = totalPopulation(units, production.queue);
  const populationCap = housingCapacity(buildings);
  const armyCap = armyCapacity(buildings);
  return send(res, 200, {
    success: true,
    city: { ...city, population, population_capacity: populationCap, army_capacity: armyCap, storage_capacity: resourceCap, crystal_storage_capacity: crystalCap, defense_bonus: defenseBonus(buildings) },
    buildings,
    units,
    productionQueue: production.queue,
    production: { metalPerMinute: metalRate, energyPerMinute: energyRate, waterPerMinute: waterRate, crystalPerMinute: crystalRate },
    capacities: { metal_capacity: resourceCap, energy_capacity: resourceCap, water_capacity: resourceCap, crystal_capacity: crystalCap, population_capacity: populationCap, army_capacity: armyCap, defense_bonus: defenseBonus(buildings) }
  });
}

async function produceArmy(req, res) {
  const playerId = authPlayerId(req);
  if (playerId === null) return send(res, 401, { success: false, message: "Oturum bulunamadı." });
  const body = await readBody(req);
  const unitType = String(body.unitType || "").trim();
  const cfg = UNIT_CONFIG[unitType];
  if (!cfg) return send(res, 400, { success: false, message: "Geçersiz birlik türü." });

  const cityResult = await supabase("cities?select=*&player_id=eq." + encodeURIComponent(playerId) + "&limit=1");
  if (!cityResult.ok || !cityResult.data?.[0]) return send(res, 404, { success: false, message: "Koloni bulunamadı." });
  const city = cityResult.data[0];
  const buildingsResult = await supabase("buildings?select=*&city_id=eq." + encodeURIComponent(city.id));
  const buildings = buildingsResult.ok ? (buildingsResult.data || []) : [];
  const production = await syncProductionQueue(playerId, city.id);
  if (!production.ok) return send(res, 500, { success: false, message: "Üretim kuyruğu okunamadı." });
  const unitsResult = await supabase("units?select=*&city_id=eq." + encodeURIComponent(city.id));
  const units = unitsResult.ok ? (unitsResult.data || []) : [];
  const population = totalPopulation(units, production.queue);
  const capacity = housingCapacity(buildings);
  const armyCap = armyCapacity(buildings);
  if (population + cfg.population > capacity) return send(res, 400, { success: false, message: "Konut kapasitesi yetersiz.", population, population_capacity: capacity, army_capacity: armyCap });
  if (population + cfg.population > armyCap) return send(res, 400, { success: false, message: "Kışla/ordu kapasitesi yetersiz.", population, population_capacity: capacity, army_capacity: armyCap });
  const resourceCap = storageCapacity(buildings);
  const crystalCap = crystalStorageCapacity(buildings);
  const currentMetal = capResource(Number(city.metal), resourceCap);
  const currentEnergy = capResource(Number(city.energy), resourceCap);
  const currentCrystal = capResource(Number(city.crystal), crystalCap);
  if (Number(city.metal) !== currentMetal || Number(city.energy) !== currentEnergy || Number(city.crystal) !== currentCrystal) {
    const normalized = await supabase("cities?id=eq." + encodeURIComponent(city.id), {
      method: "PATCH", headers: { Prefer: "return=representation" },
      body: JSON.stringify({ metal: currentMetal, energy: currentEnergy, crystal: currentCrystal, metal_capacity: resourceCap, energy_capacity: resourceCap, water_capacity: resourceCap, crystal_capacity: crystalCap })
    });
    if (normalized.ok && normalized.data?.[0]) city = normalized.data[0];
  }
  const cost = { metal: cfg.metal, energy: cfg.energy, crystal: Number(cfg.crystal || 0) };
  if (Number(city.metal) < cost.metal || Number(city.energy) < cost.energy || Number(city.crystal) < cost.crystal) return send(res, 400, { success: false, message: "Yeterli kaynak yok.", cost });

  const barracks = Math.max(1, buildingLevel(buildings, "Kışla"));
  const duration = Math.max(10, Math.round(cfg.train * Math.max(0.35, 1 - barracks * 0.04)));
  const finishAt = new Date(Date.now() + duration * 1000).toISOString();
  const updatedCity = await supabase("cities?id=eq." + encodeURIComponent(city.id), {
    method: "PATCH", headers: { Prefer: "return=representation" }, body: JSON.stringify({ metal: Number(city.metal)-cost.metal, energy: Number(city.energy)-cost.energy, crystal: Number(city.crystal)-cost.crystal, metal_capacity: resourceCap, energy_capacity: resourceCap, water_capacity: resourceCap, crystal_capacity: crystalCap })
  });
  if (!updatedCity.ok) return send(res, 500, { success: false, message: "Kaynaklar güncellenemedi." });
  const q = await supabase("unit_production_queue", { method:"POST", headers:{Prefer:"return=representation"}, body:JSON.stringify({ player_id:playerId, city_id:city.id, unit_type:unitType, quantity:1, finish_at:finishAt }) });
  if (!q.ok) return send(res, 500, { success:false, message:"Üretim kuyruğuna eklenemedi." });
  return send(res, 200, { success:true, message: cfg.label + " üretim sırasına alındı.", production:q.data?.[0], city:updatedCity.data?.[0] || city, population, population_capacity:capacity, army_capacity:armyCap });
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
  const currentLevel = Math.max(1, Number(unit.level) || 1);

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

  if (!levelResult.ok || !levelResult.data || !levelResult.data[0]) {
    return send(res, 500, {
      success: false,
      message: "Bir sonraki seviye verisi bulunamadı."
    });
  }

  const nextStats = levelResult.data[0];

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
      message:
        "Seviye yükseltmek için yeterli kaynak yok.",
      cost: cost
    });
  }

  const cityUpdate = await supabase(
    "cities?id=eq." + encodeURIComponent(city.id),
    {
      method: "PATCH",
      headers: {
        Prefer: "return=representation"
      },
      body: JSON.stringify({
        metal: Number(city.metal) - cost.metal,
        energy: Number(city.energy) - cost.energy,
        crystal: Number(city.crystal) - cost.crystal
      })
    }
  );

  if (!cityUpdate.ok) {
    return send(res, 500, {
      success: false,
      message: "Kaynaklar güncellenemedi."
    });
  }

  const unitUpdate = await supabase(
    "units?id=eq." + encodeURIComponent(unit.id),
    {
      method: "PATCH",
      headers: {
        Prefer: "return=representation"
      },
      body: JSON.stringify({
        level: nextLevel,
        attack: Number(nextStats.attack),
        defense: Number(nextStats.defense),
        hp: Number(nextStats.hp),
        speed: Number(nextStats.speed)
      })
    }
  );

  if (!unitUpdate.ok) {
    return send(res, 500, {
      success: false,
      message: "Birlik seviyesi güncellenemedi."
    });
  }

  return send(res, 200, {
    success: true,
    message: "Birlik seviyesi yükseltildi.",
    unit: unitUpdate.data[0],
    city: cityUpdate.data[0],
    cost: cost
  });
}


async function moveColony(req, res) {
  const playerId = authPlayerId(req);
  if (playerId === null) return send(res,401,{success:false,message:"Oturum bulunamadı."});
  const body = await readBody(req);
  const x = Number(body.x), y = Number(body.y);
  if (!Number.isInteger(x) || !Number.isInteger(y) || x < 1 || x > 100 || y < 1 || y > 100) return send(res,400,{success:false,message:"X ve Y koordinatları 1-100 arasında tam sayı olmalı."});
  const cityResult=await supabase("cities?select=*&player_id=eq."+encodeURIComponent(playerId)+"&limit=1");
  if(!cityResult.ok||!cityResult.data?.[0])return send(res,404,{success:false,message:"Koloni bulunamadı."});
  const city=cityResult.data[0];
  if(Number(city.coordinate_x)===x&&Number(city.coordinate_y)===y)return send(res,400,{success:false,message:"Zaten bu koordinattasın."});
  const occupied=await supabase("cities?select=id&coordinate_x=eq."+encodeURIComponent(x)+"&coordinate_y=eq."+encodeURIComponent(y)+"&limit=1");
  if(occupied.ok&&occupied.data?.[0]&&Number(occupied.data[0].id)!==Number(city.id))return send(res,400,{success:false,message:"Bu koordinat dolu."});
  const active=await supabase("military_missions?select=id&attacker_player_id=eq."+encodeURIComponent(playerId)+"&status=in.(traveling,resolving,returning)&limit=1");
  if(active.ok&&active.data?.[0])return send(res,400,{success:false,message:"Aktif askeri sefer varken koloni koordinatı değiştirilemez."});
  const updated=await supabase("cities?id=eq."+encodeURIComponent(city.id),{method:"PATCH",headers:{Prefer:"return=representation"},body:JSON.stringify({coordinate_x:x,coordinate_y:y,updated_at:new Date().toISOString()})});
  if(!updated.ok||!updated.data?.[0])return send(res,500,{success:false,message:"Koloni koordinatı güncellenemedi."});
  return send(res,200,{success:true,message:"Koloni taşındı.",city:updated.data[0]});
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
  if (!Number.isInteger(targetPlayerId) || targetPlayerId === playerId) return send(res,400,{success:false,message:"Geçersiz hedef oyuncu."});

  const [attackerCityResult,targetCityResult] = await Promise.all([
    supabase("cities?select=*&player_id=eq."+encodeURIComponent(playerId)+"&limit=1"),
    supabase("cities?select=*&player_id=eq."+encodeURIComponent(targetPlayerId)+"&limit=1")
  ]);
  if (!attackerCityResult.ok || !attackerCityResult.data?.[0]) return send(res,404,{success:false,message:"Saldıran koloni bulunamadı."});
  if (!targetCityResult.ok || !targetCityResult.data?.[0]) return send(res,404,{success:false,message:"Hedef koloni bulunamadı."});
  const attackerCity=attackerCityResult.data[0], targetCity=targetCityResult.data[0];
  const active = await supabase("military_missions?select=id,status&attacker_player_id=eq."+encodeURIComponent(playerId)+"&status=in.(traveling,resolving,returning)&limit=1");
  if (active.ok && active.data?.[0]) return send(res,400,{success:false,message:"Zaten aktif bir seferin bulunuyor."});

  const unitsResult=await supabase("units?select=*&city_id=eq."+encodeURIComponent(attackerCity.id));
  if (!unitsResult.ok) return send(res,500,{success:false,message:"Ordu verisi alınamadı."});
  const requestedUnits=body.units&&typeof body.units==="object"?body.units:{};
  let army=(unitsResult.data||[]).filter(u=>Number(u.quantity)>0).map(u=>{
    const available=Number(u.quantity||0);
    const requested=Number(requestedUnits[u.unit_type]||0);
    return {unit_type:u.unit_type,quantity:requested,available,level:Number(u.level||1),attack:Number(u.attack||0),defense:Number(u.defense||0),hp:Number(u.hp||0),speed:Number(u.speed||100),population_cost:Number(u.population_cost||1)};
  }).filter(u=>Number.isInteger(u.quantity)&&u.quantity>0);
  for(const u of army){
    if(u.quantity>u.available) return send(res,400,{success:false,message:u.unit_type+" için gönderilecek miktar mevcut ordudan fazla."});
  }
  army=army.map(u=>{const x={...u};delete x.available;return x;});
  army=await hydrateArmyStats(army);
  if (!army.length) return send(res,400,{success:false,message:"En az bir birlik miktarı seçmelisin."});

  const distance=Math.sqrt(Math.pow(Number(targetCity.coordinate_x||0)-Number(attackerCity.coordinate_x||0),2)+Math.pow(Number(targetCity.coordinate_y||0)-Number(attackerCity.coordinate_y||0),2));
  const researchResult=await supabase("research?select=travel_speed_level,general_power_level,unit_attack_level,unit_defense_level,unit_hp_level&player_id=eq."+encodeURIComponent(playerId)+"&limit=1");
  const research=researchResult.ok&&researchResult.data?.[0]?researchResult.data[0]:{};
  const fleetSpeed=Math.max(25,Math.min(...army.map(u=>Number(u.speed||100))));
  const speedResearch=Math.max(0.25,1-Number(research.travel_speed_level||0)*0.05);
  const travelSeconds=Math.max(10,Math.round(Math.max(1,distance)*120/fleetSpeed*speedResearch));
  const attackResearch=(1+Number(research.general_power_level||0)*0.05)*(1+Number(research.unit_attack_level||0)*0.05);
  const hpResearch=1+Number(research.unit_hp_level||0)*0.05;
  const attackPower=Math.round(army.reduce((sum,u)=>sum+u.quantity*u.attack*attackResearch+u.quantity*u.hp*0.15*hpResearch,0));
  const arriveAt=new Date(Date.now()+travelSeconds*1000).toISOString();

  const departAt=new Date().toISOString();
  const missionResult=await supabase("military_missions",{method:"POST",headers:{Prefer:"return=representation"},body:JSON.stringify({attacker_player_id:playerId,defender_player_id:targetPlayerId,attacker_city_id:attackerCity.id,defender_city_id:targetCity.id,mission_type:"attack",status:"traveling",depart_at:departAt,arrive_at:arriveAt,attack_power:attackPower,army,depart_x:Number(attackerCity.coordinate_x||0),depart_y:Number(attackerCity.coordinate_y||0),target_x:Number(targetCity.coordinate_x||0),target_y:Number(targetCity.coordinate_y||0),travel_seconds:travelSeconds,fleet_speed:fleetSpeed})});
  if (!missionResult.ok || !missionResult.data?.[0]) return send(res,500,{success:false,message:"Sefer oluşturulamadı."});
  const missionId=missionResult.data[0].id;
  for(const u of army){
    const row=await supabase("units?select=id,quantity&city_id=eq."+encodeURIComponent(attackerCity.id)+"&unit_type=eq."+encodeURIComponent(u.unit_type)+"&limit=1");
    if(!row.ok||!row.data?.[0]){await supabase("military_missions?id=eq."+encodeURIComponent(missionId),{method:"DELETE"});return send(res,500,{success:false,message:"Ordu sefer için hazırlanamadı."});}
    if(Number(row.data[0].quantity)<u.quantity){await supabase("military_missions?id=eq."+encodeURIComponent(missionId),{method:"DELETE"});return send(res,400,{success:false,message:"Ordu miktarı güncel değil. Tekrar deneyin."});}
    const update=await supabase("units?id=eq."+encodeURIComponent(row.data[0].id),{method:"PATCH",headers:{Prefer:"return=minimal"},body:JSON.stringify({quantity:Number(row.data[0].quantity)-u.quantity})});
    if(!update.ok){await supabase("military_missions?id=eq."+encodeURIComponent(missionId),{method:"DELETE"});return send(res,500,{success:false,message:"Ordu sefer için hazırlanamadı."});}
  }
  return send(res,200,{success:true,message:"⚔️ Ordu sefere çıktı.",mission:{id:missionId,status:"traveling",arriveAt,travelSeconds,distance:Math.round(distance)}});
}

async function completeMissionReturn(mission,res){
  const claim=await supabase("military_missions?id=eq."+encodeURIComponent(mission.id)+"&status=eq.returning",{method:"PATCH",headers:{Prefer:"return=representation"},body:JSON.stringify({status:"completed",completed_at:new Date().toISOString()})});
  if(!claim.ok || !claim.data?.[0]){
    const current=await supabase("military_missions?id=eq."+encodeURIComponent(mission.id)+"&limit=1");
    return send(res,200,{success:true,mission:current.data?.[0]||mission});
  }
  const result=mission.result||{};
  const survivors=await hydrateArmyStats(Array.isArray(result.survivorArmy)?result.survivorArmy:[]);
  for(const u of survivors){
    if(Number(u.quantity)<=0)continue;
    const existing=await supabase("units?select=id,quantity&city_id=eq."+encodeURIComponent(mission.attacker_city_id)+"&unit_type=eq."+encodeURIComponent(u.unit_type)+"&limit=1");
    if(existing.ok&&existing.data?.[0]){
      const row=existing.data[0];
      await supabase("units?id=eq."+encodeURIComponent(row.id),{method:"PATCH",headers:{Prefer:"return=minimal"},body:JSON.stringify({quantity:Number(row.quantity||0)+Number(u.quantity),level:Number(u.level),attack:Number(u.attack),defense:Number(u.defense),hp:Number(u.hp),speed:Number(u.speed),population_cost:Number(u.population_cost)})});
    } else {
      await supabase("units",{method:"POST",headers:{Prefer:"return=minimal"},body:JSON.stringify({city_id:mission.attacker_city_id,unit_type:u.unit_type,quantity:Number(u.quantity),level:Number(u.level),attack:Number(u.attack),defense:Number(u.defense),hp:Number(u.hp),speed:Number(u.speed),population_cost:Number(u.population_cost)})});
    }
  }
  return send(res,200,{success:true,mission:claim.data[0]});
}

async function getMilitaryMission(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum bulunamadı."});
  const missionId=Number(req.query.id); if(!Number.isInteger(missionId))return send(res,400,{success:false,message:"Geçersiz sefer."});
  const m=await supabase("military_missions?id=eq."+encodeURIComponent(missionId)+"&limit=1"); if(!m.ok||!m.data?.[0])return send(res,404,{success:false,message:"Sefer bulunamadı."});
  let mission=m.data[0]; if(playerId!==Number(mission.attacker_player_id)&&playerId!==Number(mission.defender_player_id))return send(res,403,{success:false,message:"Bu sefere erişemezsin."});
  if(mission.status==="completed")return send(res,200,{success:true,mission});
  let remaining=Math.ceil((new Date(mission.arrive_at).getTime()-Date.now())/1000);
  if(mission.status==="returning"&&remaining<=0)return completeMissionReturn(mission,res);
  if(mission.status==="returning"||mission.status==="resolving"||remaining>0)return send(res,200,{success:true,mission:{id:mission.id,status:mission.status,arriveAt:mission.arrive_at,remainingSeconds:Math.max(0,remaining),result:mission.result||null,attack_power:mission.attack_power||0}});

  const claim=await supabase("military_missions?id=eq."+encodeURIComponent(mission.id)+"&status=eq.traveling",{method:"PATCH",headers:{Prefer:"return=representation"},body:JSON.stringify({status:"resolving"})});
  if(!claim.ok||!claim.data?.[0]){const reread=await supabase("military_missions?id=eq."+encodeURIComponent(mission.id)+"&limit=1");return send(res,200,{success:true,mission:reread.data?.[0]||mission});}
  mission=claim.data[0];

  const [defUnitsResult,defResearchResult,defBuildingsResult,attResearchResult]=await Promise.all([
    supabase("units?select=*&city_id=eq."+encodeURIComponent(mission.defender_city_id)),
    supabase("research?select=*&player_id=eq."+encodeURIComponent(mission.defender_player_id)+"&limit=1"),
    supabase("buildings?select=*&city_id=eq."+encodeURIComponent(mission.defender_city_id)),
    supabase("research?select=*&player_id=eq."+encodeURIComponent(mission.attacker_player_id)+"&limit=1")
  ]);
  const rawDefenders=defUnitsResult.data||[],defR=defResearchResult.data?.[0]||{},defB=defBuildingsResult.data||[],attR=attResearchResult.data?.[0]||{};
  const army=await hydrateArmyStats(Array.isArray(mission.army)?mission.army:[]);
  const defenders=await hydrateArmyStats(rawDefenders.filter(u=>Number(u.quantity||0)>0).map(u=>({unit_type:u.unit_type,quantity:Number(u.quantity||0),level:Number(u.level||1),population_cost:Number(u.population_cost||1)})));
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
  for(const u of defenders){const loss=Number(defenderLosses[u.unit_type]||0);if(loss)await supabase("units?id=eq."+encodeURIComponent(u.id),{method:"PATCH",headers:{Prefer:"return=minimal"},body:JSON.stringify({quantity:Math.max(0,Number(u.quantity||0)-loss)})});}

  const targetCityResult=await supabase("cities?select=*&id=eq."+encodeURIComponent(mission.defender_city_id)+"&limit=1");
  const attackerCityResult=await supabase("cities?select=*&id=eq."+encodeURIComponent(mission.attacker_city_id)+"&limit=1");
  const targetCity=targetCityResult.data?.[0],attackerCity=attackerCityResult.data?.[0];
  const targetBuildings=defB;
  const targetStorage=storageCapacity(targetBuildings),targetCrystalStorage=crystalStorageCapacity(targetBuildings);
  const attackerBuildingsResult=await supabase("buildings?select=*&city_id=eq."+encodeURIComponent(mission.attacker_city_id));
  const attackerBuildings=attackerBuildingsResult.data||[],attackerStorage=storageCapacity(attackerBuildings),attackerCrystalStorage=crystalStorageCapacity(attackerBuildings);
  const lootRate=result==="Zafer"?0.10:0;
  const loot={metal:targetCity?Math.floor(Number(targetCity.metal||0)*lootRate):0,energy:targetCity?Math.floor(Number(targetCity.energy||0)*lootRate):0,water:targetCity?Math.floor(Number(targetCity.water||0)*lootRate):0,crystal:targetCity?Math.floor(Number(targetCity.crystal||0)*lootRate):0};
  if(targetCity&&attackerCity&&result==="Zafer"){
    const available={metal:Math.max(0,targetStorage-Number(targetCity.metal||0)),energy:Math.max(0,targetStorage-Number(targetCity.energy||0)),water:Math.max(0,targetStorage-Number(targetCity.water||0)),crystal:Math.max(0,targetCrystalStorage-Number(targetCity.crystal||0))};
    loot.metal=Math.min(loot.metal,Math.max(0,attackerStorage-Number(attackerCity.metal||0)));
    loot.energy=Math.min(loot.energy,Math.max(0,attackerStorage-Number(attackerCity.energy||0)));
    loot.water=Math.min(loot.water,Math.max(0,attackerStorage-Number(attackerCity.water||0)));
    loot.crystal=Math.min(loot.crystal,Math.max(0,attackerCrystalStorage-Number(attackerCity.crystal||0)));
    await supabase("cities?id=eq."+encodeURIComponent(targetCity.id),{method:"PATCH",headers:{Prefer:"return=minimal"},body:JSON.stringify({metal:Math.max(0,Number(targetCity.metal||0)-loot.metal),energy:Math.max(0,Number(targetCity.energy||0)-loot.energy),water:Math.max(0,Number(targetCity.water||0)-loot.water),crystal:Math.max(0,Number(targetCity.crystal||0)-loot.crystal)})});
    await supabase("cities?id=eq."+encodeURIComponent(attackerCity.id),{method:"PATCH",headers:{Prefer:"return=minimal"},body:JSON.stringify({metal:Math.min(attackerStorage,Number(attackerCity.metal||0)+loot.metal),energy:Math.min(attackerStorage,Number(attackerCity.energy||0)+loot.energy),water:Math.min(attackerStorage,Number(attackerCity.water||0)+loot.water),crystal:Math.min(attackerCrystalStorage,Number(attackerCity.crystal||0)+loot.crystal)})});
  }
  const outbound=Math.max(10,Math.round((new Date(mission.arrive_at).getTime()-new Date(mission.depart_at).getTime())/1000));
  const returnAt=new Date(Date.now()+outbound*1000).toISOString();
  const attackerX=Number(mission.depart_x),attackerY=Number(mission.depart_y),defenderX=Number(mission.target_x),defenderY=Number(mission.target_y);
  const battlePoints=calculateBattlePoints(result,attackPower,defensePower);
  const report={version:3,result,attackPower,defensePower,rawAttackPower:Math.round(rawAttackPower),rawDefensePower:Math.round(rawDefensePower),defenseBonus:wallBonus,advantageRatio:Number(ratio.toFixed(4)),attackerLosses,defenderLosses,loot,survivorArmy,returnAt,battleAt:new Date().toISOString(),battlePoints,winnerPlayerId:result==="Zafer"?Number(mission.attacker_player_id):result==="Yenilgi"?Number(mission.defender_player_id):null,attackerX:Number.isFinite(attackerX)?attackerX:null,attackerY:Number.isFinite(attackerY)?attackerY:null,defenderX:Number.isFinite(defenderX)?defenderX:null,defenderY:Number.isFinite(defenderY)?defenderY:null,attackerBreakdown,defenderBreakdown};
  await supabase("battle_reports",{method:"POST",headers:{Prefer:"return=minimal"},body:JSON.stringify({attacker_player_id:Number(mission.attacker_player_id),defender_player_id:Number(mission.defender_player_id),result:JSON.stringify(report),attack_power:attackPower,defense_power:defensePower,attacker_losses:attackerLosses,defender_losses:defenderLosses,loot,battle_points:battlePoints,winner_player_id:report.winnerPlayerId})});
  const updated=await supabase("military_missions?id=eq."+encodeURIComponent(mission.id)+"&status=eq.resolving",{method:"PATCH",headers:{Prefer:"return=representation"},body:JSON.stringify({status:"returning",arrive_at:returnAt,attack_power:attackPower,result:report})});
  if(!updated.ok||!updated.data?.[0])return send(res,500,{success:false,message:"Savaş sonucu kaydedilemedi."});
  return send(res,200,{success:true,mission:{...updated.data[0],remainingSeconds:outbound}});
}

async function syncResearchCityResources(playerId, city, buildings, research){
  const now=Date.now();
  const lastProduction=new Date(city.last_production_at||city.updated_at||now).getTime();
  const elapsedMinutes=Math.max(0,Math.floor((now-lastProduction)/60000));
  const prodMultiplier=1+Number(research?.production_level||0)*0.10;
  const crystalMultiplier=1+Number(research?.crystal_level||0)*0.08;
  const metalRate=buildingLevel(buildings,"Metal Madeni")*10*prodMultiplier;
  const energyRate=buildingLevel(buildings,"Enerji Santrali")*10*prodMultiplier;
  const waterRate=buildingLevel(buildings,"Su Arıtma")*10*prodMultiplier;
  const crystalRate=buildingLevel(buildings,"Kristal Madeni")*5*crystalMultiplier;
  const resourceCap=storageCapacity(buildings);
  const crystalCap=crystalStorageCapacity(buildings);
  const populationCap=housingCapacity(buildings);
  const armyCap=armyCapacity(buildings);
  const next={...city};
  if(elapsedMinutes>0){
    next.metal=capResource(Number(city.metal)+metalRate*elapsedMinutes,resourceCap);
    next.energy=capResource(Number(city.energy)+energyRate*elapsedMinutes,resourceCap);
    next.water=capResource(Number(city.water)+waterRate*elapsedMinutes,resourceCap);
    next.crystal=capResource(Number(city.crystal)+crystalRate*elapsedMinutes,crystalCap);
  }
  const needsUpdate=elapsedMinutes>0 || Number(city.metal_capacity)!==resourceCap || Number(city.energy_capacity)!==resourceCap || Number(city.water_capacity)!==resourceCap || Number(city.crystal_capacity)!==crystalCap || Number(city.population_capacity)!==populationCap || Number(city.army_capacity)!==armyCap;
  if(needsUpdate){
    const patch={metal:next.metal,energy:next.energy,water:next.water,crystal:next.crystal,metal_capacity:resourceCap,energy_capacity:resourceCap,water_capacity:resourceCap,crystal_capacity:crystalCap,population_capacity:populationCap,army_capacity:armyCap};
    if(elapsedMinutes>0)patch.last_production_at=new Date(lastProduction+elapsedMinutes*60000).toISOString();
    const updated=await supabase("cities?id=eq."+encodeURIComponent(city.id),{method:"PATCH",headers:{Prefer:"return=representation"},body:JSON.stringify(patch)});
    if(updated.ok&&updated.data?.[0])return updated.data[0];
  }
  next.metal=capResource(Number(next.metal),resourceCap);
  next.energy=capResource(Number(next.energy),resourceCap);
  next.water=capResource(Number(next.water),resourceCap);
  next.crystal=capResource(Number(next.crystal),crystalCap);
  return next;
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
  if(!research){const cr=await supabase("research",{method:"POST",headers:{Prefer:"return=representation"},body:JSON.stringify({player_id:playerId,production_level:0,combat_level:0,defense_level:0,crystal_level:0,general_power_level:0,unit_attack_level:0,unit_defense_level:0,unit_hp_level:0,travel_speed_level:0})});if(!cr.ok)return send(res,500,{success:false,message:"Araştırma kaydı oluşturulamadı."});research=cr.data[0];}
  if(research.upgrade_ready_at){research=await finalizeResearch(research);}
  city=await syncResearchCityResources(playerId,city,buildings,research);
  if(research.upgrade_ready_at)return send(res,400,{success:false,message:"Başka bir araştırma zaten sürüyor.",finishAt:research.upgrade_ready_at});
  const level=Math.max(0,Number(research[column]||0)); if(level>=15)return send(res,400,{success:false,message:"Bu araştırma zaten 15. seviyede."});
  const mult=level+1; const cost={metal:base[type].metal*mult,energy:base[type].energy*mult,crystal:base[type].crystal*mult}; if(Number(city.metal)<cost.metal||Number(city.energy)<cost.energy||Number(city.crystal)<cost.crystal)return send(res,400,{success:false,message:"Yeterli kaynak yok.",cost,available:{metal:Number(city.metal||0),energy:Number(city.energy||0),crystal:Number(city.crystal||0)}});
  const duration=60+level*45; const finishAt=new Date(Date.now()+duration*1000).toISOString();
  const cu=await supabase("cities?id=eq."+encodeURIComponent(city.id),{method:"PATCH",headers:{Prefer:"return=representation"},body:JSON.stringify({metal:Number(city.metal)-cost.metal,energy:Number(city.energy)-cost.energy,crystal:Number(city.crystal)-cost.crystal})}); if(!cu.ok)return send(res,500,{success:false,message:"Kaynaklar güncellenemedi."}); city=cu.data[0];
  const ru=await supabase("research?id=eq."+encodeURIComponent(research.id),{method:"PATCH",headers:{Prefer:"return=representation"},body:JSON.stringify({upgrade_ready_at:finishAt,pending_column:column})}); if(!ru.ok)return send(res,500,{success:false,message:"Araştırma başlatılamadı."});
  return send(res,200,{success:true,message:"🔬 Araştırma başlatıldı.",research:ru.data[0],city,finishAt,duration});
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
  const playerIds = Array.from(new Set(
    reportsRaw.flatMap(function(report){
      return [Number(report.attacker_player_id), Number(report.defender_player_id)];
    }).filter(function(id){ return Number.isInteger(id) && id > 0; })
  ));
  let cityMap = {};
  if (playerIds.length) {
    const cityQuery = "cities?select=player_id,coordinate_x,coordinate_y&player_id=in.(" + playerIds.join(",") + ")";
    const citiesResult = await supabase(cityQuery);
    if (citiesResult.ok) {
      (citiesResult.data || []).forEach(function(city){
        cityMap[Number(city.player_id)] = city;
      });
    }
  }

  const reports = reportsRaw.map(
    function(report) {
      const battle = report.result && typeof report.result === "object" ? report.result : {};
      const attackerCity = cityMap[Number(report.attacker_player_id)] || {};
      const defenderCity = cityMap[Number(report.defender_player_id)] || {};
      return {
        ...report,
        attacker_username: playerMap[report.attacker_player_id] || "Bilinmeyen Oyuncu",
        defender_username: playerMap[report.defender_player_id] || "Bilinmeyen Oyuncu",
        attacker_x: battle.attackerX ?? attackerCity.coordinate_x ?? null,
        attacker_y: battle.attackerY ?? attackerCity.coordinate_y ?? null,
        defender_x: battle.defenderX ?? defenderCity.coordinate_x ?? null,
        defender_y: battle.defenderY ?? defenderCity.coordinate_y ?? null
      };
    }
  );

  return send(res, 200, {
    success: true,
    reports: reports
  });
}

async function upgradeBuilding(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum bulunamadı."});
  const body=await readBody(req); const buildingType=String(body.building||"").trim();
  const costs={"Metal Madeni":{metal:500,energy:100,water:50,crystal:25},"Enerji Santrali":{metal:400,energy:50,water:50,crystal:20},"Su Arıtma":{metal:350,energy:75,water:50,crystal:20},"Kristal Madeni":{metal:600,energy:120,water:40,crystal:30},"Kışla":{metal:450,energy:100,water:50,crystal:25},"Merkez Bina":{metal:750,energy:150,water:100,crystal:50},"Depo":{metal:700,energy:120,water:60,crystal:40},"Konut":{metal:500,energy:80,water:100,crystal:25},"Sur":{metal:900,energy:150,water:80,crystal:80},"Savunma Kulesi":{metal:1200,energy:220,water:100,crystal:100}};
  if(!costs[buildingType])return send(res,400,{success:false,message:"Geçersiz bina."});
  const cityResult=await supabase("cities?select=*&player_id=eq."+encodeURIComponent(playerId)+"&limit=1");if(!cityResult.ok||!cityResult.data?.[0])return send(res,404,{success:false,message:"Koloni bulunamadı."});const city=cityResult.data[0];
  const br=await supabase("buildings?select=*&city_id=eq."+encodeURIComponent(city.id)+"&building_type=eq."+encodeURIComponent(buildingType)+"&limit=1");if(!br.ok)return send(res,500,{success:false,message:"Bina verisi alınamadı."});
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
    "Savunma Kulesi":{"Merkez Bina":5,"Sur":2}
  };
  const allBuildings=await supabase("buildings?select=building_type,level&city_id=eq."+encodeURIComponent(city.id));
  const prerequisiteLevels={}; for(const b of (allBuildings.data||[]))prerequisiteLevels[b.building_type]=Math.max(0,Number(b.level||0));
  const reqs=prerequisites[buildingType]||{};
  for(const [reqName,reqLevel] of Object.entries(reqs)){
    if(Number(prerequisiteLevels[reqName]||0)<Number(reqLevel))return send(res,400,{success:false,message:buildingType+" için "+reqName+" seviye "+reqLevel+" gerekli.",required:{building:reqName,level:reqLevel}});
  }
  if(current>=maxLevel)return send(res,400,{success:false,message:buildingType+" maksimum seviye olan "+maxLevel+" seviyeye ulaştı."});
  const multiplier=current+1;
  const cost={metal:costs[buildingType].metal*multiplier,energy:costs[buildingType].energy*multiplier,water:costs[buildingType].water*multiplier,crystal:costs[buildingType].crystal*multiplier};
  if(Number(city.metal)<cost.metal||Number(city.energy)<cost.energy||Number(city.water)<cost.water||Number(city.crystal)<cost.crystal)return send(res,400,{success:false,message:"Yeterli kaynak bulunmuyor.",cost,nextLevel:current+1});
  const duration=45+current*45, finishAt=new Date(Date.now()+duration*1000).toISOString();
  const cu=await supabase("cities?id=eq."+encodeURIComponent(city.id),{method:"PATCH",headers:{Prefer:"return=representation"},body:JSON.stringify({metal:Number(city.metal)-cost.metal,energy:Number(city.energy)-cost.energy,water:Number(city.water)-cost.water,crystal:Number(city.crystal)-cost.crystal})});if(!cu.ok)return send(res,500,{success:false,message:"Kaynaklar güncellenemedi."});
  let bu;
  if(building) bu=await supabase("buildings?id=eq."+encodeURIComponent(building.id),{method:"PATCH",headers:{Prefer:"return=representation"},body:JSON.stringify({is_under_construction:true,upgrade_ready_at:finishAt})});
  else bu=await supabase("buildings",{method:"POST",headers:{Prefer:"return=representation"},body:JSON.stringify({city_id:city.id,building_type:buildingType,level:0,is_under_construction:true,upgrade_ready_at:finishAt})});
  if(!bu.ok)return send(res,500,{success:false,message:"İnşaat başlatılamadı."});
  return send(res,200,{success:true,message:buildingType+" için seviye "+(current+1)+" inşaatı başlatıldı.",city:cu.data?.[0]||city,building:bu.data?.[0],finishAt,duration,cost,nextLevel:current+1,maxLevel});
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
  if(site.site_type==="alliance")return send(res,400,{success:false,message:"İttifak bölgeleri henüz keşfe açık değil."});

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
    const raw=r.result&&typeof r.result==='object'?r.result:safeBattleResult(r.result);
    const result=typeof raw==='object'?String(raw.result||''):String(raw||'');
    const points=Number(r.battle_points ?? (typeof raw==='object'?raw.battlePoints:0))||0;
    const winner=Number(r.winner_player_id ?? (typeof raw==='object'?raw.winnerPlayerId:0))||0;
    if(winner && score[winner])score[winner].battle_points+=points;
    else if(result==='Zafer' && score[r.attacker_player_id])score[r.attacker_player_id].battle_points+=points;
    if(result==='Zafer'&&winner&&score[winner])score[winner].wins+=1;
    else if(result==='Yenilgi'){const loser=winner===Number(r.attacker_player_id)?Number(r.defender_player_id):Number(r.attacker_player_id);if(score[loser])score[loser].losses+=1;}
    else if(result==='Beraberlik'){if(score[r.attacker_player_id])score[r.attacker_player_id].draws+=1;if(score[r.defender_player_id])score[r.defender_player_id].draws+=1;}
  }
  for(const x of Object.values(score))x.score=Math.round(x.colony_level*100+x.army_power+x.battle_points+x.research_level*30+x.buildings_level*20+x.wins*25);
  const rankings=Object.values(score).sort((a,b)=>b.score-a.score||b.battle_points-a.battle_points||b.army_power-a.army_power||b.wins-a.wins||a.username.localeCompare(b.username,'tr')).map((x,i)=>({...x,rank:i+1,is_me:x.player_id===playerId}));
  const me=rankings.find(x=>x.player_id===playerId)||null;
  return send(res,200,{success:true,rankings,me});
}


const TRADE_RESOURCES = new Set(["metal","energy","water","crystal"]);
const TRADE_MAX_AMOUNT = 1000000000;

function normalizeTradeResource(value){
  const resource=String(value||"").trim().toLowerCase();
  return TRADE_RESOURCES.has(resource) ? resource : null;
}

async function getTradeCity(playerId){
  const r=await supabase("cities?select=*&player_id=eq."+encodeURIComponent(playerId)+"&limit=1");
  if(!r.ok||!r.data?.[0])return {error:"Koloni bulunamadı."};
  return {city:r.data[0]};
}

async function getTradeOffers(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum gerekli."});
  const r=await supabase("trade_offers?select=id,creator_player_id,give_resource,give_amount,want_resource,want_amount,status,expires_at,created_at,accepted_by_player_id,accepted_at&order=created_at.desc&limit=100");
  if(!r.ok)return send(res,500,{success:false,message:"Ticaret teklifleri alınamadı."});
  const offers=(r.data||[]).filter(x=>x.status==="open"&&(!x.expires_at||new Date(x.expires_at).getTime()>Date.now())||x.creator_player_id===playerId||x.accepted_by_player_id===playerId);
  const ids=[...new Set(offers.map(x=>Number(x.creator_player_id)).filter(Boolean))];
  const names={};
  if(ids.length){
    const pr=await supabase("players?select=id,username&id=in.("+ids.join(",")+")");
    for(const p of (pr.data||[]))names[p.id]=p.username;
  }
  return send(res,200,{success:true,offers:offers.map(x=>({...x,creator_username:names[x.creator_player_id]||"Oyuncu"})),serverTime:new Date().toISOString()});
}

async function createTradeOffer(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum gerekli."});
  const body=await readBody(req);
  const giveResource=normalizeTradeResource(body.giveResource);
  const wantResource=normalizeTradeResource(body.wantResource);
  const giveAmount=Math.floor(Number(body.giveAmount||0));
  const wantAmount=Math.floor(Number(body.wantAmount||0));
  const hours=Math.min(72,Math.max(1,Math.floor(Number(body.durationHours||24))));
  if(!giveResource||!wantResource||giveResource===wantResource)return send(res,400,{success:false,message:"Geçerli ve farklı iki kaynak seçmelisin."});
  if(giveAmount<1||wantAmount<1||giveAmount>TRADE_MAX_AMOUNT||wantAmount>TRADE_MAX_AMOUNT)return send(res,400,{success:false,message:"Ticaret miktarı geçersiz."});
  const rpc=await supabase("rpc/create_trade_offer",{method:"POST",body:JSON.stringify({p_player_id:Number(playerId),p_give_resource:giveResource,p_give_amount:giveAmount,p_want_resource:wantResource,p_want_amount:wantAmount,p_expires_at:new Date(Date.now()+hours*3600000).toISOString()})});
  if(!rpc.ok)return send(res,rpc.status>=400&&rpc.status<500?400:500,{success:false,message:rpc.data?.message||"Ticaret teklifi oluşturulamadı."});
  return send(res,200,{success:true,message:"🤝 Ticaret teklifi oluşturuldu.",offer:rpc.data?.offer||rpc.data,serverTime:new Date().toISOString()});
}

async function acceptTradeOffer(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum gerekli."});
  const body=await readBody(req); const offerId=Math.floor(Number(body.offerId||0));
  if(!offerId)return send(res,400,{success:false,message:"Geçerli teklif seçilmedi."});
  const rpc=await supabase("rpc/accept_trade_offer",{method:"POST",body:JSON.stringify({p_offer_id:offerId,p_acceptor_player_id:Number(playerId)})});
  if(!rpc.ok)return send(res,rpc.status>=400&&rpc.status<500?400:500,{success:false,message:rpc.data?.message||"Ticaret gerçekleştirilemedi."});
  return send(res,200,{success:true,message:"✅ Ticaret tamamlandı.",transaction:rpc.data?.transaction||rpc.data,serverTime:new Date().toISOString()});
}

async function cancelTradeOffer(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum gerekli."});
  const body=await readBody(req); const offerId=Math.floor(Number(body.offerId||0));
  if(!offerId)return send(res,400,{success:false,message:"Geçerli teklif seçilmedi."});
  const rpc=await supabase("rpc/cancel_trade_offer",{method:"POST",body:JSON.stringify({p_offer_id:offerId,p_player_id:Number(playerId)})});
  if(!rpc.ok)return send(res,rpc.status>=400&&rpc.status<500?400:500,{success:false,message:rpc.data?.message||"Ticaret teklifi iptal edilemedi."});
  return send(res,200,{success:true,message:"↩️ Teklif iptal edildi ve kaynakların iade edildi.",serverTime:new Date().toISOString()});
}

async function getTradeHistory(req,res){
  const playerId=authPlayerId(req); if(playerId===null)return send(res,401,{success:false,message:"Oturum gerekli."});
  const r=await supabase("trade_transactions?select=id,offer_id,seller_player_id,buyer_player_id,give_resource,give_amount,want_resource,want_amount,created_at&or=(seller_player_id.eq."+encodeURIComponent(playerId)+",buyer_player_id.eq."+encodeURIComponent(playerId)+")&order=created_at.desc&limit=50");
  if(!r.ok)return send(res,500,{success:false,message:"Ticaret geçmişi alınamadı."});
  return send(res,200,{success:true,history:r.data||[]});
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
    if (action === "attack") {
  return await attackPlayer(req, res);
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
