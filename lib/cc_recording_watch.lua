-- Transport state machine: capture before a recording, wait for finalized MIDI, run once.
local M = {}
function M.new(api, callbacks)
    local self = {project=nil, baseline=nil, pass=nil, pending=nil, previous=0, next_capture=0}
    function self:poll()
        local project=api.EnumProjects(-1,'')
        local now=api.time_precise()
        local state=project and api.GetPlayStateEx(project) or 0
        if project ~= self.project then
            self.project, self.baseline, self.pass, self.pending=project,nil,nil,nil
            self.previous=state -- Starting while recording never processes that incomplete pass.
            self.next_capture=0
        end
        if not project then return end
        local recording=state & 4 ~= 0
        if recording and self.previous & 4 == 0 then
            -- Refresh at the first recording frame, protecting even edits made
            -- just before Record. Any first-frame recorded points are protected too.
            self.pass=callbacks.capture(project,self.baseline)
            self.baseline,self.pending=nil,nil
        end
        if self.pass and not recording then
            if not self.pending then self.pending={since=now} end
            if state == 0 and now-self.pending.since >= .4 then
                local fingerprint=callbacks.fingerprint(project,self.pass)
                if fingerprint == self.pending.fingerprint then
                    local pass=self.pass
                    self.pass,self.pending,self.baseline=nil,nil,nil
                    callbacks.optimize(project,pass)
                    self.next_capture=0
                else
                    self.pending.fingerprint=fingerprint
                    self.pending.since=now
                end
            elseif state ~= 0 then self.pending.since=now end
        end
        self.previous=state
        if not recording and not self.pass and now >= self.next_capture then
            self.baseline=callbacks.capture(project,self.baseline)
            self.next_capture=now+.15
        end
    end
    function self:reset()
        self.project,self.baseline,self.pass,self.pending=nil,nil,nil,nil
    end
    return self
end
return M
