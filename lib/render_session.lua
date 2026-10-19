-- Idempotent cleanup shared by normal completion, errors, and REAPER atexit.
local M = {}
function M.new()
    local steps, finished, errors = {}, false, {}
    return {
        add = function(label, restore)
            assert(not finished, "Cannot add cleanup after finishing")
            steps[#steps + 1] = { label = label, restore = restore }
        end,
        finish = function()
            if finished then return {} end
            finished = true
            for _, step in ipairs(steps) do
                local ok, reason = pcall(step.restore)
                if not ok then errors[#errors + 1] = step.label .. ": " .. tostring(reason) end
            end
            return errors
        end
    }
end
return M
