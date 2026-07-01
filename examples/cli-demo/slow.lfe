(task
  (let* ((wait (tool sleep
                 (ms 60000)
                 (timeout-ms 120000))))
    (return wait)))
