-- AI Builder Industry Patch
-- Adds cargo type parameters to vanilla industries so the AI Builder can understand supply chains

function data()
    return {
        postRunFn = function(params)
            -- Define the supply chain mappings
            local industryData = {
                -- Raw material producers
                ["industry/iron_ore_mine.con"] = {
                    inputs = {},
                    outputs = {"IRON_ORE"},
                    capacity = {100},
                    sources = {}
                },
                ["industry/coal_mine.con"] = {
                    inputs = {},
                    outputs = {"COAL"},
                    capacity = {100},
                    sources = {}
                },
                ["industry/forest.con"] = {
                    inputs = {},
                    outputs = {"WOOD"},
                    capacity = {100},
                    sources = {}
                },
                ["industry/oil_well.con"] = {
                    inputs = {},
                    outputs = {"OIL"},
                    capacity = {100},
                    sources = {}
                },
                ["industry/quarry.con"] = {
                    inputs = {},
                    outputs = {"STONE"},
                    capacity = {100},
                    sources = {}
                },
                ["industry/farm.con"] = {
                    inputs = {},
                    outputs = {"GRAIN"},
                    capacity = {100},
                    sources = {}
                },

                -- Processing industries
                ["industry/steel_mill.con"] = {
                    inputs = {"IRON_ORE", "COAL"},
                    outputs = {"STEEL"},
                    capacity = {100},
                    sources = {1, 1}  -- 1 source each
                },
                ["industry/sawmill.con"] = {
                    inputs = {"WOOD"},
                    outputs = {"PLANKS"},
                    capacity = {100},
                    sources = {1}
                },
                ["industry/oil_refinery.con"] = {
                    inputs = {"OIL"},
                    outputs = {"FUEL", "PLASTIC"},
                    capacity = {50, 50},
                    sources = {1}
                },
                ["industry/food_processing_plant.con"] = {
                    inputs = {"GRAIN"},
                    outputs = {"FOOD"},
                    capacity = {100},
                    sources = {1}
                },

                -- Final goods producers
                ["industry/tools_factory.con"] = {
                    inputs = {"STEEL", "PLANKS"},
                    outputs = {"TOOLS"},
                    capacity = {100},
                    sources = {1, 1}
                },
                ["industry/machine_factory.con"] = {
                    inputs = {"STEEL", "PLASTIC"},
                    outputs = {"MACHINES"},
                    capacity = {100},
                    sources = {1, 1}
                },
                ["industry/furniture_factory.con"] = {
                    inputs = {"PLANKS"},
                    outputs = {"GOODS"},
                    capacity = {100},
                    sources = {1}
                },
                ["industry/construction_materials_plant.con"] = {
                    inputs = {"STONE", "STEEL"},
                    outputs = {"CONSTRUCTION_MATERIALS"},
                    capacity = {100},
                    sources = {1, 1}
                },
                ["industry/chemical_plant.con"] = {
                    inputs = {"OIL"},
                    outputs = {"PLASTIC"},
                    capacity = {100},
                    sources = {1}
                },
            }

            -- Apply patches to each industry
            for fileName, data in pairs(industryData) do
                local index = api.res.constructionRep.find(fileName)
                if index >= 0 then
                    local rep = api.res.constructionRep.get(index)
                    if rep and rep.params then
                        -- Add input cargo types
                        if #data.inputs > 0 then
                            table.insert(rep.params, {
                                key = "inputCargoTypeForAiBuilder",
                                name = "AI Builder Inputs",
                                values = data.inputs,
                                defaultIndex = 0,
                                uiType = "BUTTON"
                            })
                        end

                        -- Add output cargo types
                        if #data.outputs > 0 then
                            table.insert(rep.params, {
                                key = "outputCargoTypeForAiBuilder",
                                name = "AI Builder Outputs",
                                values = data.outputs,
                                defaultIndex = 0,
                                uiType = "BUTTON"
                            })
                        end

                        -- Add capacity
                        if #data.capacity > 0 then
                            local capacityStrings = {}
                            for _, v in ipairs(data.capacity) do
                                table.insert(capacityStrings, tostring(v))
                            end
                            table.insert(rep.params, {
                                key = "capacityForAiBuilder",
                                name = "AI Builder Capacity",
                                values = capacityStrings,
                                defaultIndex = 0,
                                uiType = "BUTTON"
                            })
                        end

                        -- Add sources count
                        if #data.sources > 0 then
                            local sourcesStrings = {}
                            for _, v in ipairs(data.sources) do
                                table.insert(sourcesStrings, tostring(v))
                            end
                            table.insert(rep.params, {
                                key = "sourcesCountForAiBuilder",
                                name = "AI Builder Sources",
                                values = sourcesStrings,
                                defaultIndex = 0,
                                uiType = "BUTTON"
                            })
                        end
                    end
                end
            end
        end
    }
end
