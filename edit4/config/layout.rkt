#lang racket

;;; edit4/config/layout.rkt —— 区域（面板槽）声明 + 区域快捷键（纯数据）
;;;
;;; region-specs，每条： (id side size (member ...) active anchor shown?)
;;;   id     : 符号；键表 / region 命令按它定位（如 (region-toggle 'sidebar)）
;;;   side   : left | right | top | bottom
;;;   size   : auto（按屏宽算的侧栏宽度）| 整数
;;;              left/right = 宽度；top/bottom = 高度
;;;   member : 面板名（字符串，如 "*tree*" / "*buffers*" / "*log*"）
;;;   active : 启动时显示的成员（字符串）
;;;   anchor : root（贴根，跨整屏）| main（贴主区，让开状态栏）
;;;   shown? : shown（启动即显示）| hidden（启动隐藏，C-b / C-l 等再显示）
;;;
;;; region-keys，每条： (key-pattern scope command-data ...)
;;;   key-pattern  : 同 keymap 的 binding（如 (key b ctrl) / (key tab)）
;;;   scope        : always | (region ID) | (panel "*x*") | ...
;;;   command-data : (name arg ...)，按顺序跑
;;;   区域 id 只写在这里和 region-specs 两处，改布局不用碰代码。
;;;
;;; 想让 tree 出现在顶部：把 tree 单独拆成一条 top 区域，键表同步指向它，例如
;;;   region-specs: (tree top 8 ("*tree*") "*tree*" root shown)
;;;                 (buffers left auto ("*buffers*") "*buffers*" root hidden)
;;;   region-keys : ((key b ctrl) always (region-toggle tree))
;;;                 ((key t alt)  always (region-activate tree "*tree*") (region-focus tree))

(provide region-specs region-keys)

(define region-specs
  '((sidebar left   auto ("*tree*" "*buffers*") "*tree*" root shown)
    (log     bottom 6    ("*log*")              "*log*"  main hidden)))

(define region-keys
  '(((key b ctrl) always          (region-toggle sidebar))
    ((key l ctrl) always          (region-toggle log))
    ((key b alt)  always          (region-cycle sidebar 1) (region-focus sidebar))
    ((key tab)    (region sidebar) (region-cycle sidebar 1) (region-focus sidebar))
    ((key t alt)  always          (region-activate sidebar "*tree*") (region-focus sidebar))))
