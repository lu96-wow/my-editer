#lang racket

;;; 编辑操作表 / 自插入 / 鼠标落点测试。

(require rackunit
         "../config/keymap/buffer.rkt"
         "../config/keymap/default.rkt"
         "../main.rkt")

(define area (rect 0 0 20 6))

(define (make-state text)
  (define engine (make-engine))
  (define-values (store actions)
    (resource-open resource-store-empty
                   #:name "main"
                   #:text text
                   #:key-table (buffer-key-table #f text)))
  (define editor-panel
    (make-panel 'editor 'editor #:views '(1) #:active 1))
  (define layout
    (make-layout #:root (make-leaf 'editor)
                 #:panels (hash 'editor editor-panel)
                 #:focus 'editor))
  (define state
    (make-app-state #:layout layout
                    #:resources store
                    #:keymap default-keymap
                    #:area area))
  (define s0 (run-actions state engine actions))
  (let-values ([(cache bytes) (render-frame s0 engine #f)])   ; 首帧落 viewport 尺寸
    (void cache)
    (void bytes))
  (values s0 engine))

(define (press* state engine tok)
  (define-values (s actions) (step state (key-event tok)))
  (values (run-actions s engine actions) actions))

(define (press state engine tok)
  (let-values ([(s actions) (press* state engine tok)])
    (void actions)
    s))

(define (type-string state engine str)
  (for/fold ([s state]) ([c (in-string str)])
    (press s engine (key c))))

;; ---------- 自插入：token 就是 (tag . bytes)，文本直接取 bytes ----------
(check-equal? (self-insert-text (key 'a)) "a")
(check-equal? (self-insert-text (key 'A)) "A")
(check-equal? (self-insert-text (key 'space)) " ")
(check-equal? (self-insert-text (key #\中)) "中")
(check-false (self-insert-text (key 'left)))
(check-false (self-insert-text (key 'enter)))
(check-false (self-insert-text (key 'a 'ctrl)))
(check-equal? (self-insert-bytes (key 'a)) #"a")
(check-equal? (self-insert-bytes (key #\中)) (string->bytes/utf-8 "中"))
(check-false (self-insert-bytes (key 'left)))
;; 防御：误标成 'key 的多字节转义序列不能整串插入
(check-false (self-insert-bytes (key-token 'key #"\e[A")))

(check-equal? (self-insert-char (key 'a)) #\a)
(check-equal? (self-insert-char (key 'A)) #\A)
(check-equal? (self-insert-char (key 'space)) #\space)
(check-equal? (self-insert-char (key #\中)) #\中)
(check-false (self-insert-char (key 'a 'ctrl)))
(check-false (self-insert-char (key 'left)))
(check-false (self-insert-char (key 'enter)))
(check-false (self-insert-char (key 'escape)))

;;; ---------- 打字 / 换行 / Tab / 删除 ----------
(define-values (s0 e0) (make-state ""))
(check-equal? (engine-view-text e0 1) "")

(define s1 (type-string s0 e0 "Hi"))
(check-equal? (engine-view-text e0 1) "Hi")

(define s2 (press s1 e0 (key 'enter)))
(define s3 (press s2 e0 (key 'tab)))
(check-equal? (engine-view-text e0 1) "Hi\n  ")

(define s4 (press s3 e0 (key 'backspace)))
(check-equal? (engine-view-text e0 1) "Hi\n ")

(define s5 (press s4 e0 (key 'home)))
(define s6 (press s5 e0 (key 'delete)))
(check-equal? (engine-view-text e0 1) "Hi\n")

;; Delete 删后一个字符（新状态，避免落在最后空行行尾）
(define-values (d0 de) (make-state "Hi"))
(define d1 (press d0 de (key 'delete)))
(check-equal? (engine-view-text de 1) "i")

;;; ---------- 导航：C-a / C-e ----------
(define-values (n0 ne) (make-state "Hi"))
(define n1 (type-string n0 ne ""))
(define n2 (press n1 ne (key 'left)))
(define n3 (press n2 ne (key 'a 'ctrl)))
(check-equal? (engine-view-point-column ne 1) 0)
(define n4 (press n3 ne (key 'e 'ctrl)))
(check-equal? (engine-view-point-column ne 1) 2)

;;; ---------- Shift+方向扩展选区，再插入就替换掉 ----------
(define-values (mA mAa) (press* n4 ne (key 'right 'shift)))
(check-equal? (map view-action-kind mAa) '(nav))
(check-equal? (view-action-data (car mAa)) '(right #t))
(define mB (press mA ne (key 'X)))
(check-equal? (engine-view-text ne 1) "HiX")

;;; ---------- C-k 删到行尾 ----------
(define-values (k0 ke) (make-state "abcd"))
(define k1 (press k0 ke (key 'right)))
(check-equal? (engine-view-point-column ke 1) 1)
(define-values (k2 kActions) (press* k1 ke (key 'k 'ctrl)))
(check-equal? (map view-action-kind kActions) '(kill-line))
(check-equal? (engine-view-text ke 1) "a")

;;; ---------- PageUp / PageDown：滚一屏，光标跟着走 ----------
(define-values (pg0 pge)
  (make-state (string-join (for/list ([i (in-range 20)]) (format "line-~a" i)) "\n")))
;; viewport 高 6 -> 一屏 5 行
(define pg1 (press pg0 pge (key 'pagedown)))
(check-equal? (engine-view-point-line pge 1) 5)
(define pg2 (press pg1 pge (key 'pagedown)))
(check-equal? (engine-view-point-line pge 1) 10)
(define pg3 (press pg2 pge (key 'pageup)))
(check-equal? (engine-view-point-line pge 1) 5)

;;; ---------- 撤销 / 重做 ----------
(define k3 (press k2 ke (key 'z 'ctrl)))
(check-equal? (engine-view-text ke 1) "abcd")
(define k4 (press k3 ke (key 'y 'ctrl)))
(check-equal? (engine-view-text ke 1) "a")

;;; ---------- 鼠标点 buffer：光标落在点击处 ----------
(define-values (c0 ce) (make-state "ab\ncd"))
(define-values (c1 cActions) (step c0 (mouse-event 'press 1 1)))
(check-equal? (map view-action-kind cActions) '(point))
(check-equal? (view-action-data (car cActions)) '(1 1 #f))
(define c2 (run-actions c1 ce cActions))
(define c3 (press c2 ce (key '!)))
(check-equal? (engine-view-text ce 1) "ab\nc!d")

;; 点在边框上（row 0 / col 0 是上边框）：只聚焦，不落点
(define bordered
  (let-values ([(layout* ok?) (layout-panel-update
                               (app-state-layout c0) 'editor
                               (λ (p) (make-panel (panel-id p) (panel-kind p)
                                                  #:views (panel-views p)
                                                  #:active (panel-active p)
                                                  #:borders '(up down left right))))])
    (void ok?)
    (struct-copy app-state c0 [layout layout*])))
(define-values (_b1 bActions) (step bordered (mouse-event 'press 0 0)))
(check-equal? bActions '())

;;; ---------- 文档下方空白：落到最近有效行，列夹到行尾 ----------
(define-values (z0 ze) (make-state "ab\ncd"))
(define-values (z1 zActions) (step z0 (mouse-event 'press 5 1)))
(check-equal? (map view-action-kind zActions) '(point))
(define z2 (run-actions z1 ze zActions))
(check-equal? (engine-view-point-line ze 1) 1)
(check-equal? (engine-view-point-column ze 1) 1)
(define-values (z3 z3Actions) (step z0 (mouse-event 'press 5 9)))
(define z4 (run-actions z3 ze z3Actions))
(check-equal? (engine-view-point-line ze 1) 1)
(check-equal? (engine-view-point-column ze 1) 2)

;;; ---------- 焦点不在 editor：可打印字符不会插入 ----------
(define-values (x0 xe) (make-state "keep"))
(void (engine-create-buffer! xe 2 "*status*" "status"))
(void (engine-create-view! xe 2 2))
(define status-panel
  (make-panel 'status 'status #:views '(2) #:active 2 #:fixed-h 1))
(define-values (xl ok?) (layout-panel-attach (app-state-layout x0)
                                            'editor 'down status-panel))
(check-true ok?)
(check-equal? (app-state-focus-resource x0) 1)
(define x1 (struct-copy app-state x0 [layout (layout-set-focus xl 'status)]))
;; focus-resource 是派生查询：直接改 layout 后仍然正确。
(check-false (app-state-focus-resource x1))
(define-values (x2 xActions) (step x1 (key-event (key 'a))))
(check-equal? xActions '())
(check-equal? (engine-view-text xe 1) "keep")
(check-true (string-contains? (app-state-flash x2) "unbound"))

;; C-i 到不了“Ctrl+I”这个身份，但它就是 Tab：编辑表里的 Tab 绑定会被触发。
(check-equal? (key 'i 'ctrl) (key 'tab))

(displayln "edit-tui-rebuild/test/edit.rkt: ok")
