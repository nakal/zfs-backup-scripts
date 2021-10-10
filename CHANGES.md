# Recent changes

## 2021-10-10

There is a small change in configuration files. Please replace `pigz_cpu_num`
with `compress_cpu_num`. The multithreading option is reused for the new ZSTD
compression now, so the name makes more sense.
