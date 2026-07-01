(task
  (let* ((boom (tool fail
                 (mode crash)
                 (reason kaboom))))
    (return boom)))
