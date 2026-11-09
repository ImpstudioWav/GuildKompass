local ADDON, ns = ...

ns.VERSION = "1.22.4"
ns.PREFIX  = "GKompass3"      -- maks 16 tegn (ny fra 1.11: navn uten realm)

-- Raids som addonen kjenner til. (Skjult fra og med 1.4 – beholdt til senere.)
-- "open" er bare standardverdien første gang; offiserer slår raids av/på
-- i spillet med  /gk raid <KODE> på|av  (synkes til hele guilden).
--
-- attune: quests (quest-ID-er der én fullført holder) og/eller items (holder at
-- spilleren har itemet i bags/bank). required = false betyr at attunementen er
-- kjekk å ha, men ikke nødvendig for å komme inn (MC kan gås til via BRD).
-- Kommer det nye raids i WoW: Forever, legg dem til her.
ns.RAIDS = {
    { key = "MC",   name = "Molten Core",         instanceID = 409, size = 40, minLevel = 60, open = true,
      attune = { quests = { 7848 }, required = false } },                       -- Attunement to the Core
    { key = "ONY",  name = "Onyxia's Lair",       instanceID = 249, size = 40, minLevel = 60, open = true,
      attune = { quests = { 6502, 6602 }, items = { 16309 }, required = true } }, -- Drakefire Amulet
    { key = "BWL",  name = "Blackwing Lair",      instanceID = 469, size = 40, minLevel = 60, open = false,
      attune = { quests = { 7761 }, required = true } },                         -- Blackhand's Command
    { key = "ZG",   name = "Zul'Gurub",           instanceID = 309, size = 20, minLevel = 60, open = false },
    { key = "AQ20", name = "Ruins of Ahn'Qiraj",  instanceID = 509, size = 20, minLevel = 60, open = false },
    { key = "AQ40", name = "Temple of Ahn'Qiraj", instanceID = 531, size = 40, minLevel = 60, open = false },
    { key = "NAXX", name = "Naxxramas",           instanceID = 533, size = 40, minLevel = 60, open = false,
      attune = { quests = { 9121, 9122, 9123 }, required = true } },             -- The Dread Citadel
}

-- Reserve-ikoner for talenttrær (klassiske vanilla-ikoner), brukes hvis
-- spilleren ikke har sendt ikonet selv (eldre versjon av addonen).
local I = "Interface\\Icons\\"
ns.SPEC_ICONS = {
    MAGE    = { Arcane = I .. "Spell_Holy_MagicalSentry", Fire = I .. "Spell_Fire_FireBolt02",
                Frost = I .. "Spell_Frost_FrostBolt02" },
    WARRIOR = { Arms = I .. "Ability_Rogue_Eviscerate", Fury = I .. "Ability_Warrior_InnerRage",
                Protection = I .. "INV_Shield_06" },
    ROGUE   = { Assassination = I .. "Ability_Rogue_Eviscerate", Combat = I .. "Ability_BackStab",
                Subtlety = I .. "Ability_Stealth" },
    PRIEST  = { Discipline = I .. "Spell_Holy_WordFortitude", Holy = I .. "Spell_Holy_HolyBolt",
                Shadow = I .. "Spell_Shadow_ShadowWordPain" },
    DRUID   = { Balance = I .. "Spell_Nature_StarFall", ["Feral Combat"] = I .. "Ability_Racial_BearForm",
                Feral = I .. "Ability_Racial_BearForm", Restoration = I .. "Spell_Nature_HealingTouch" },
    HUNTER  = { ["Beast Mastery"] = I .. "Ability_Hunter_BeastTaming", Marksmanship = I .. "Ability_Marksmanship",
                Survival = I .. "Ability_Hunter_SwiftStrike" },
    PALADIN = { Holy = I .. "Spell_Holy_HolyBolt", Protection = I .. "Spell_Holy_DevotionAura",
                Retribution = I .. "Spell_Holy_AuraOfLight" },
    SHAMAN  = { Elemental = I .. "Spell_Nature_Lightning", Enhancement = I .. "Spell_Nature_LightningShield",
                Restoration = I .. "Spell_Nature_MagicImmunity" },
    WARLOCK = { Affliction = I .. "Spell_Shadow_DeathCoil", Demonology = I .. "Spell_Shadow_Metamorphosis",
                Destruction = I .. "Spell_Shadow_RainOfFire" },
}

-- Profesjoner (navn slik de står i engelsk klient).
ns.PROFESSIONS = {
    ["Alchemy"]        = "primary",
    ["Blacksmithing"]  = "primary",
    ["Enchanting"]     = "primary",
    ["Engineering"]    = "primary",
    ["Herbalism"]      = "primary",
    ["Leatherworking"] = "primary",
    ["Mining"]         = "primary",
    ["Skinning"]       = "primary",
    ["Tailoring"]      = "primary",
    ["Cooking"]        = "secondary",
    ["First Aid"]      = "secondary",
    ["Fishing"]        = "secondary",
}

function ns.FindRaid(instanceID, name)
    for _, r in ipairs(ns.RAIDS) do
        if (instanceID and r.instanceID == instanceID) or (name and r.name == name) then
            return r
        end
    end
end

function ns.RaidByKey(key)
    if not key then return nil end
    key = key:upper()
    for _, r in ipairs(ns.RAIDS) do
        if r.key == key then return r end
    end
end
