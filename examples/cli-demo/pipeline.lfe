(run
  (step read file_read
    (args (path "input.txt") (root "/tmp/soma-demo")))
  (step process echo
    (args (from_step read)))
  (step write file_write
    (args (path "output.txt") (root "/tmp/soma-demo") (bytes (from_step process)))))
