# Processes

The worker owns its running total. Callers can only change it by sending a
typed message that includes a reply process; the worker has no shared mutable
state with `старт`.

```sh
./panos demo/03-processes/main.ps
```

Expected result: `42`.
