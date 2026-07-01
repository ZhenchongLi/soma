(task
  (let* ((read (tool file_read
                 (path "input.txt")
                 (root "/tmp/soma-demo")))
         (process (tool echo
                    (from read)))
         (write (tool file_write
                  (path "output.txt")
                  (root "/tmp/soma-demo")
                  (bytes (from process)))))
    (return write)))
