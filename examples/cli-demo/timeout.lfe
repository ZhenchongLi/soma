(task
  (let* ((wait (tool sleep
                 (ms 3000)
                 (timeout-ms 500))))
    (return wait)))
