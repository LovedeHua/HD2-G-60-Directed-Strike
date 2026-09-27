local M = {}; M.__index = M
function M.new(sink, limit)
    return setmetatable({sink=sink, limit=limit or 2048, count=0}, M)
end
function M:emit(event, fields)
    if type(self.sink) ~= 'function' or self.count >= self.limit then return end
    self.count = self.count + 1
    -- Sink failures must not interfere with targeting or vanilla behavior.
    pcall(self.sink, {event=event, fields=fields or {}})
end
return M
