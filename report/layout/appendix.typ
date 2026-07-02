#import "@preview/lilaq:0.5.0" as lq

This appendix collects the two budget sweeps omitted from @results for space, `density` and
`mutate`. Both exhibit the same flat-versus-growing pattern as @fig-sweep, with smaller
magnitude: the moving collectors stay flat as the budget grows while mark-sweep's run time
climbs.

#figure(
  grid(columns: 2, column-gutter: 8pt,
    lq.diagram(
      width: 6.2cm, height: 4.6cm,
      title: [density], xlabel: [Heap budget], ylabel: [Run time (ms)],
      xlim: (-0.3, 6.3),
      xaxis: (ticks: ((0, [16K]), (2, [64K]), (4, [256K]), (6, [1M]))),
      legend: (position: left + top),
      lq.plot((0, 1, 2, 3, 4, 5, 6), (169.2, 170.3, 169.5, 186.3, 200.9, 214.5, 276.7), label: [m-sweep], mark: "o"),
      lq.plot((0, 1, 2, 3, 4, 5, 6), (168.1, 164.4, 165.0, 163.3, 163.9, 166.5, 165.4), label: [m-compact], mark: "s"),
      lq.plot((1, 2, 3, 4, 5, 6), (165.0, 164.7, 163.0, 164.2, 165.8, 164.4), label: [cheney], mark: "x"),
      lq.plot((0, 1, 2, 3, 4, 5, 6), (169.7, 167.1, 167.2, 166.8, 167.6, 167.9, 167.8), label: [generational], mark: "+"),
    ),
    lq.diagram(
      width: 6.2cm, height: 4.6cm,
      title: [mutate], xlabel: [Heap budget], ylabel: [Run time (ms)],
      xlim: (0.7, 6.3),
      xaxis: (ticks: ((2, [64K]), (4, [256K]), (6, [1M]))),
      legend: (position: left + top),
      lq.plot((1, 2, 3, 4, 5, 6), (20.3, 21.4, 26.0, 30.0, 34.2, 39.9), label: [m-sweep], mark: "o"),
      lq.plot((1, 2, 3, 4, 5, 6), (20.6, 19.1, 18.4, 18.1, 18.3, 18.2), label: [m-compact], mark: "s"),
      lq.plot((2, 3, 4, 5, 6), (19.1, 18.3, 18.4, 19.1, 17.9), label: [cheney], mark: "x"),
      lq.plot((1, 2, 3, 4, 5, 6), (21.4, 19.9, 19.2, 19.6, 21.0, 21.9), label: [generational], mark: "+"),
    ),
  ),
  kind: image, supplement: [Figure],
  caption: [Run time versus heap budget for `density` (left) and `mutate` (right), mean over
  $n = 8$ seeds. As in @fig-sweep, the moving and generational collectors stay flat while
  mark-sweep climbs; the magnitude is smaller because both workloads spend more of their time
  in mutator work. The 8 MiB anchor (no collection) is omitted; `mutate` does not survive
  below 32 KiB (64 KiB for Cheney) and Cheney does not survive `density` below 32 KiB.],
) <fig-sweep-extra>
