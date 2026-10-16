#lang racket

;;; command/tui.rkt —— 命令层的 tui 适配：事件 → token → 键表
;;;
;;;   1. `event->key`    key-event    → 键令牌（其余 → #f）
;;;      `event->mouse`  mouse-event  → 鼠标令牌（其余 → #f）
;;;      `mouse-position` mouse-event → 0-based 屏幕 (row, col)
;;;   2. `key-reader`    有状态地读一个**键序列**：喂事件，命中叶子就**返回 command**，
;;;                      命中前缀就继续等，没命中就报告 —— 由宿主决定怎么办。
;;;                      匹配逻辑在 keymap.rkt 的纯 `matcher`；本层只把 event → token。
;;;                      读键器通过 matcher 持有 keytable，故**运行时动态合并立刻生效**。
;;;                      只用纯匹配时，外部状态机可直接用 `matcher`，不碰本模块。
;;;
;;; 命令层**只路由、不调用**：命中叶子时返回 command，宿主自己执行。
;;; 于是鼠标/键盘统一，handler 能拿位置；也支持数据驱动 world（ctx 由宿主造）。
;;; 命令带说明 / 输入需求时（command-note / command-input），宿主据此显示 note 或先收输入。
;;; 鼠标无序列：`(keytable-lookup mousetable (list (event->mouse ev)))`。
;;;
;;; 读键循环本身在宿主：命中/位置/上下文表 / 拖拽状态都在宿主。

(provide event->key event->mouse mouse-position
         (struct-out key-reader)
         make-key-reader
         key-reader-feed!
         key-reader-reset!
         key-reader-pending
         key-reader-pending-string
         key-reader-table
         (all-from-out "key.rkt" "mouse.rkt" "keymap.rkt"))

(require tui "key.rkt" "mouse.rkt" "keymap.rkt")

(define mod-order '(ctrl alt shift))

(define (mods->symbols m)
  (for/list ([s (in-list mod-order)]
             [on? (in-list (list (mods-ctrl? m) (mods-alt? m) (mods-shift? m)))]
             #:when on?)
    s))

;;; ---------- 事件 → token ----------

(define (event->key ev)
  (and (key-event? ev)
       (apply key (key-event-key ev) (mods->symbols (key-event-mods ev)))))

(define (event->mouse ev)
  (and (mouse-event? ev)
       (apply mouse (mouse-event-action ev) (mouse-event-button ev)
              (mods->symbols (mouse-event-mods ev)))))

;; mouse-event 的 (x, y) 是 1-based；core 屏幕坐标是 0-based (row, col)。
;; 返回 (values row col)。
(define (mouse-position ev)
  (values (max 0 (sub1 (mouse-event-y ev)))
          (max 0 (sub1 (mouse-event-x ev)))))

;;; ---------- 有状态读键（event → token → 纯 matcher） ----------
;;;
;;; 匹配逻辑在 keymap.rkt 的纯 matcher；本层只把 event 解码成 token。

(struct key-reader (matcher) #:transparent #:mutable)
;; matcher : matcher   纯序列匹配器（持有 keytable + 已按序列）

(define (make-key-reader kt) (key-reader (make-matcher kt)))

(define (key-reader-reset! kr)
  (matcher-reset! (key-reader-matcher kr)))

(define (key-reader-pending kr)
  (matcher-pending (key-reader-matcher kr)))

(define (key-reader-pending-string kr)
  (string-join (map key->string (or (key-reader-pending kr) '())) " "))

;; 活动表（便捷访问器；运行时并表用 keytable-merge!，换整份用 set-keytable-tables!）
(define (key-reader-table kr)
  (matcher-table (key-reader-matcher kr)))

;; 喂一个事件 → (values status cmd)
;;   'command : 命中叶子，cmd = 命中的 command（宿主自己执行 / 处理 input），清空前缀
;;   'prefix  : 命中前缀，继续等下一个键（cmd = #f）
;;   'unbound : 没命中，清空前缀（宿主可拿原事件当文本 / 提示）
;;   'ignored : 不是按键事件（鼠标 / resize / null），键表不管
(define (key-reader-feed! kr ev)
  (define k (event->key ev))
  (if k
      (matcher-feed! (key-reader-matcher kr) k)
      (values 'ignored #f)))
