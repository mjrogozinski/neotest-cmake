return {
  new = function(opts)
    local buf = vim.api.nvim_create_buf(false, true)
    return {
      get_bufnr = function()
        return buf
      end,
      start = function(self, task)
        self.task = task
        require('nio').run(function()
          require('nio').scheduler()
          local ok, success = xpcall(function()
            return opts.run(task)
          end, debug.traceback)
          require('nio').scheduler()
          require('neotest-cmake.overseer').finish(task, ok and success == true)
          if not ok then
            vim.notify(success, vim.log.levels.ERROR)
          end
        end)
      end,
      reset = function(self)
        if self.task then
          for _, child in ipairs(require('overseer').list_tasks({ include_ephemeral = true })) do
            if child.parent_id == self.task.id then
              child:dispose(true)
            end
          end
        end
      end,
      stop = function() end,
      dispose = function()
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end,
    }
  end,
}
