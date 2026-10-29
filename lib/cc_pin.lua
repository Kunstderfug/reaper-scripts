-- Optional native window integration; MIDI processing has no dependency on JS.
local M={}
function M.open(api,g,title,width,height)
    local pin={ enabled=false }
    local supported=api.JS_Window_Find and api.JS_Window_SetZOrder and api.JS_Window_SetTitle
    -- Resolve this instance only, even if another optimizer window is open.
    local initial=supported and (title..' '..api.genGuid()) or title
    g.init(initial,width,height,0)
    function pin.set(enabled)
        if not pin.window then return false end
        if not api.JS_Window_SetZOrder(pin.window,enabled and 'TOPMOST' or 'NOTOPMOST') then return false end
        pin.enabled=enabled
        api.SetExtState('GPhil_CC_Gestures','pinned',enabled and '1' or '0',true)
        return true
    end
    function pin.update()
        if supported and not pin.window then
            pin.window=api.JS_Window_Find(initial,true)
            if pin.window then
                api.JS_Window_SetTitle(pin.window,title)
                pin.set(api.GetExtState('GPhil_CC_Gestures','pinned')~='0')
            end
        end
    end
    return pin
end
return M
