#lang racket

;;; edit-tui-rebuild/runtime/tui-adapter.rkt —— tui raw 事件 -> app 事件
;;;
;;; 用 tui 的字节级接口 read-event/raw（返回值 (values type data mods)）：
;;;   type : 'key 'ctrl 'alt 'utf8 'mod-seq 'up 'down … 'mouse 'paste 'resize
;;;   data : 原始字节（mouse / resize 是结构化值）
;;;
;;; 键事件原样变成 (key-token tag bytes)，不在这一层解码 char / symbol。
;;; mods 不单独保存：tag + bytes 已经表达了它（'ctrl 隐含 ctrl，
;;; 'mod-seq 的修饰位在 CSI 参数里）。

(require racket/match
         (prefix-in tui: tui)
         (prefix-in a: "../app/event.rkt")
         "../command/api.rkt")

(provide tui-event->app)

;; 鼠标：raw data = (action button x y mods) | (scroll dir x y mods)
(define (raw-mouse->app data)
  (match data
    [(list 'press _b x y _m)
     (a:mouse-event 'press (max 0 (sub1 y)) (max 0 (sub1 x)))]
    [(list 'release _b x y _m)
     (a:mouse-event 'release (max 0 (sub1 y)) (max 0 (sub1 x)))]
    [(list 'move _b x y _m)
     (a:mouse-event 'move (max 0 (sub1 y)) (max 0 (sub1 x)))]
    [(list 'scroll _btn dir x y _m)
     (a:mouse-event (if (eq? dir 'up) 'scroll-up 'scroll-down)
                    (max 0 (sub1 y)) (max 0 (sub1 x)))]
    [_ #f]))

;; raw (type data mods) -> app event
(define (tui-event->app type data _mods)
  (case type
    [(null) #f]
    [(resize) (a:resize-event (car data) (cdr data))]
    [(paste) (a:paste-event data)]                 ; 原始字节
    [(mouse) (raw-mouse->app data)]
    [else (a:key-event (raw->key type data))]))
