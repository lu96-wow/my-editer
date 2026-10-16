#lang racket

;;; command/tui.rkt —— 命令层的 tui 适配：事件 → token → 键表
;;;
;;;   1. `event->key`    key-event    → 键令牌（其余 → #f）
;;;      `event->mouse`  mouse-event  → 鼠标令牌（其余 → #f）
;;;      `mouse-position` mouse-event → 0-based 屏幕 (row, col)
;;;   2. `key-reader`    有状态地读一个**键序列**：喂事件，命中叶子就**返回**过程，
;;;                      命中前缀就继续等，没命中就报告 —— 由宿主决定怎么办。
;;;                      读键器持有 keytable 的引用，故**运行时动态合并的表立刻生效**。
;;;
;;; 命令层**只路由、不调用**：命中叶子时返回 proc，宿主自己 `(proc ctx)`。
;;; 于是鼠标/键盘统一，handler 能拿位置；也支持数据驱动 world（proc 拿得到 world）。
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

;;; ---------- 有状态读键（键序列） ----------

(struct key-reader (table typed) #:transparent #:mutable)
;; table : keytable        活动表列表（运行时可变，读键器直接引用）
;; typed : (listof key?)   已按下的前缀键（正序），用于状态栏显示

(define (make-key-reader kt) (key-reader kt '()))

(define (key-reader-reset! kr)
  (set-key-reader-typed! kr '()))

(define (key-reader-pending kr)
  (define t (key-reader-typed kr))
  (and (pair? t) t))

(define (key-reader-pending-string kr)
  (string-join (map key->string (key-reader-typed kr)) " "))

;; 喂一个事件 → (values status proc)
;;   'command : 命中叶子，proc = 命中的过程（宿主自己调用），清空前缀
;;   'prefix  : 命中前缀，继续等下一个键（proc = #f）
;;   'unbound : 没命中，清空前缀（宿主可拿原事件当文本 / 提示）
;;   'ignored : 不是按键事件（鼠标 / resize / null），键表不管
(define (key-reader-feed! kr ev)
  (define k (event->key ev))
  (cond
    [(not k) (values 'ignored #f)]
    [else
     (define typed (append (key-reader-typed kr) (list k)))
     (define-values (status entry) (keytable-lookup (key-reader-table kr) typed))
     (case status
       [(command) (key-reader-reset! kr) (values 'command entry)]
       [(prefix) (set-key-reader-typed! kr typed) (values 'prefix #f)]
       [else (key-reader-reset! kr) (values 'unbound #f)])]))
