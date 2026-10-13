#lang racket

;;; edit4/config/layout.rkt —— 面板组合 + 槽位 + 区域快捷键（纯数据）
;;;
;;; 把「面板怎么组合」和「槽位放哪 / 多大 / 显隐」拆成两张表——组合是内容概念，
;;; 槽位是布局概念；键表只认槽位 id。于是 tree+buffers 作为**一个组合整体**操作
;;; （C-b 切它、M-b 在组内循环、M-t 切到 tree），与键表语义一致，天然不可拆。
;;;
;;; panel-groups，每条： (group-id (member ...) active)
;;;   member : 面板名（字符串，如 "*tree*" / "*buffers*" / "*log*"）
;;;   组内成员互斥显示；active 是启动时显示的成员。
;;;
;;; docks，每条： (dock-id side size min anchor shown?)
;;;   dock-id 引用一个 panel-group，并决定它放哪、多大、启动是否显示。
;;;   side   : left | right | top | bottom
;;;   size   : auto（按 side 取横向宽度 / 纵向高度）| 整数（left/right 宽度，top/bottom 高度）
;;;   min    : auto（同 size 的轴向最小）| 整数（展开下限；拖到更小/隐藏后再显示不会夹成 0）
;;;   anchor : root（贴根，跨整屏）| main（贴主区，让开状态栏）
;;;   shown? : shown | hidden
;;;
;;; region-keys，每条： (key-pattern scope command-data ...)
;;;   key-pattern  : 同 keymap 的 binding（如 (key b ctrl) / (key tab)）
;;;   scope        : always | (region DOCK-ID) | (panel "*x*") | ...
;;;   command-data : (name arg ...)，按顺序跑
;;;   只引用 dock-id；组合怎么分组由 panel-groups 决定，键表不用管。
;;;
;;; 想让 tree+buffers 整体到顶部：只改 docks 里 sidebar 的 side/size 即可：
;;;   (sidebar top 8 2 root shown)   ; size 此时是高度，2 是最小高度
;;; 要真正拆成两个独立面板，则各自建一个组合 + 槽位（键表随之指新 dock-id）——
;;; 这是显式决定，不再是「顺手写个单成员 region」。

(provide region-specs panel-groups docks region-keys)

(require "sidebar.rkt")

(define panel-groups
  '((sidebar ("*tree*" "*buffers*") "*tree*")
    (status  ("*status*" "*input*") "*status*")   ; 状态栏 / 输入行共用一个 dock
    (log     ("*log*")              "*log*")))

;; (id side size min anchor shown?)
;;   size/min 可为 auto：按 side 取横向（宽）或纵向（高）策略（boot 解析）。
(define docks
  (list (list 'sidebar 'left    'auto 'auto 'root 'shown)   ; 文件树在顶部（横向 dock）
        (list 'status  'bottom 1     1     'main 'shown)   ; 常显；prompt 时切到 *input*
        (list 'log     'bottom 6     2     'main 'hidden)))

(define region-keys
  '(((key b ctrl) always          (region-toggle sidebar))
    ((key l ctrl) always          (region-toggle log))
    ((key b alt)  always          (region-cycle sidebar 1) (region-focus sidebar))
    ((key tab)    (region sidebar) (region-cycle sidebar 1) (region-focus sidebar))
    ((key t alt)  always          (region-activate sidebar "*tree*") (region-focus sidebar))))

;; region-specs：组合 + 槽位合成 boot / 作用域消费的形式
;;   (id side size (member ...) active anchor shown? min)
(define (group-of id)
  (or (assq id panel-groups) (error 'layout "未知组合: ~a" id)))

(define region-specs
  (for/list ([d (in-list docks)])
    (define g (group-of (car d)))
    (list (car d) (cadr d) (caddr d) (cadr g) (caddr g)
          (list-ref d 4) (list-ref d 5) (list-ref d 3))))
