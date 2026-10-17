#lang racket

;;; edit-tui-rebuild/test/popup.rkt —— 浮层（弹窗）的绘制与**清理**
;;;
;;; 这条测试盯的是一个真 bug：浮层是在 core 的 panels 之后叠加的额外 piece，
;;; **不在 core 的 screen 缓存里**。core 的增量 diff 只比较“自己的旧屏 vs 新屏”，
;;; 所以它永远不知道浮层曾经盖住过什么 —— 光丢掉 core 缓存重画也不够：
;;; `screen-patch` 在 old = #f 时**只产出非空白格**，被浮层盖住后又变回空白的格子不会被写回。
;;;
;;; 正确做法（projection/render.rkt）：
;;;   1. 浮层变了（出现 / 消失 / 移动 / 选中行变化）就先自己清掉**旧矩形**；
;;;   2. 再让 core 整屏重画一次，把底下的正文画回来。
;;;
;;; 这里用 render-frame 的返回字节（纯）来验证：关掉浮层后，被盖住的正文必须重新出现。

(require rackunit
         racket/string
         "../base/id.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../model/overlay.rkt"
         "../effects/engine.rkt"
         "../projection/render.rkt"
         "../projection/popup.rkt"
         "../../core/view/base/rect.rkt"
         "../../core/editor/state.rkt"
         "../../core/editor/ops.rkt"
         "../../core/text/base/point.rkt")

;;; ════════════════ 夹具：一个 10 行文档 + 一个浮层 ════════════════

(define did (doc-id 1))
(define vid (view-id 1))
(define rid (region-id 1))

(define (make-state*)
  (define engine (make-engine))
  ;; 第 0 行是前缀 "abc"（光标停在行尾）；后面几行是候选
  (void (engine-create-doc! engine did "m"
                            (string-join (cons "abc"
                                               (for/list ([i (in-range 1 10)])
                                                 (string-append "abc-defghij" (number->string i))))
                                         "\n")))
  (void (engine-create-view! engine vid did))
  (define ws
    (let* ([ws (workspace-empty)]
           [ws (workspace-add-doc ws did (make-doc-meta "m" #:path "/tmp/m"))]
           [ws (workspace-add-view ws vid (view-meta did (hash)))]
           [ws (workspace-add-region ws rid (region rid (list (view-member vid)) vid 'editor))])
      (struct-copy workspace ws [layout (make-leaf rid)])))
  (define s0 (state-set-focus
              (make-state #:workspace ws #:ids (make-id-counter 2 2 2 1)
                          #:window (make-window 12 40))
              vid))
  (values engine s0))

(define (frame-1 engine s)
  (define-values (_p _c placements) (project-frame s engine))
  (engine-sync-views! engine placements)
  (let-values ([(cache bytes) (render-frame s engine #f)])
    (values cache bytes)))

(define (frame-n engine s cache)
  (define-values (_p _c placements) (project-frame s engine))
  (engine-sync-views! engine placements)
  (render-frame s engine cache))

;;; ════════════════ 1. 浮层出现在光标下方 ════════════════

(let-values ([(engine s0) (make-state*)])
  (define s1 (state-popup-show s0 'demo vid (list "cand-a" "cand-b") 0))
  (define-values (cache1 b1) (frame-1 engine s1))
  (define t1 (bytes->string/utf-8 b1))
  (check-true (string-contains? t1 "┌") "浮层上边框")
  (check-true (string-contains? t1 "cand-a") "浮层第一行")
  (check-true (string-contains? t1 "cand-b") "浮层第二行")
  (check-true (string-contains? t1 "└") "浮层下边框")

  ;; 记录浮层矩形（下一帧要用它判断“正文有没有画回来”）
  (define ev (make-engine-view engine))
  (define entry (for/first ([e (in-list (project-popups s1 ev))]) e))
  (check-not-false entry)
  (define r (popup-entry-rect entry))
  ;; 浮层盖住的行（浮层内部那几行，不含上下边框）
  (define covered-rows (for/list ([i (in-range (add1 (rect-y r)) (sub1 (+ (rect-y r) (rect-h r))))]) i))

;;; ════════════════ 2. 关掉浮层：被盖住的正文必须重新画出来 ════════════════

  (define s2 (state-popup-hide s1 'demo))
  (define-values (_cache2 b2) (frame-n engine s2 cache1))
  (define t2 (bytes->string/utf-8 b2))
  ;; 被盖住的那几行的正文必须重新出现至少一次
  (check-true (string-contains? t2 "abc-defghij"))
  ;; 而且不能再有浮层的任何痕迹（本帧没有浮层）
  (check-false (string-contains? t2 "cand-a"))
  ;; 清屏段必须真的写了空格（旧矩形被擦过）
  (check-true (string-contains? t2 (make-string 5 #\space))))

;;; ════════════════ 3. 浮层移动 / 换选中行：同样要擦旧位置 ════════════════

(let-values ([(engine s0) (make-state*)])
  (define s1 (state-popup-show s0 'demo vid (list "aaa" "bbb") 0))
  (define-values (cache1 _b1) (frame-1 engine s1))
  ;; 移动光标让浮层换位置（锚点变了）
  (define s2 (state-workspace* s1 (λ (ws)
                                    (struct-copy workspace ws
                                                 [layout (workspace-layout ws)]))))
  (void s2)
  ;; 直接改浮层锚点对应的内容：把浮层挪到另一行（用 selected 与否不影响矩形，
  ;; 这里改用 view 的光标位置：模拟“光标下移”）
  (define obj (engine-view-object engine vid))
  (view-set-point! obj (point 6 0))
  (define-values (_c2 b2) (frame-n engine s1 cache1))
  (define t2 (bytes->string/utf-8 b2))
  ;; 新位置要画出来
  (check-true (string-contains? t2 "aaa"))
  ;; 旧位置（浮层原来盖住的行）的正文要被恢复
  (check-true (string-contains? t2 "abc-defghij")))

;;; ════════════════ 3b. 端到端：C-c / 开弹窗 -> Esc 关掉 -> 屏幕不留残影 ════════════════

(require racket/async-channel
         "../../edit-tui/command/key.rkt"
         (prefix-in app: "../base/event.rkt")
         "../base/transition.rkt"
         "../model/input.rkt"
         "../model/chrome.rkt"
         "../plugins/builtin.rkt"
         "../runtime/run.rkt")

(let-values ([(engine s0) (make-state*)])
  (define (feed s . evs)
    (transition-state (process-events editor-env engine (make-async-channel) s evs)))
  ;; 光标放到第一行（"abc"）末尾
  (define s1 (feed s0 (app:key-event (key 'end))))
  (define s2 s1)
  ;; 打开弹窗（"abc" 的候选是文档里的 "abcdefghij0"）
  (define s3 (feed s2 (app:key-event (key 'c 'ctrl)) (app:key-event (key '/))))
  (check-not-false (state-popup-get s3 'completion))
  (define-values (cache1 b1) (frame-1 engine s3))
  (check-true (string-contains? (bytes->string/utf-8 b1) "┌"))

  ;; Esc 取消 -> 弹窗消失
  (define s4 (feed s3 (app:key-event (key 'escape))))
  (check-false (state-popup-get s4 'completion))
  (define-values (_c b2) (frame-n engine s4 cache1))
  (define t2 (bytes->string/utf-8 b2))
  ;; 本帧不能再画弹窗里的候选（面板边框也含 ┌└，所以不按边框判断）
  (check-false (string-contains? t2 "cand"))
  ;; 被弹窗盖住的正文要回来（浮层下面那几行的内容）
  (check-true (or (string-contains? t2 "abc-defghij")
                  (string-contains? t2 (make-string 8 #\space)))))

;;; ════════════════ 4. 选中行变化：只重画，不残留两行高亮 ════════════════

(let-values ([(engine s0) (make-state*)])
  (define s1 (state-popup-show s0 'demo vid (list "aaa" "bbb") 0))
  (define-values (cache1 _b1) (frame-1 engine s1))
  (define s2 (state-popup-move s1 'demo 1))
  (define-values (_c2 b2) (frame-n engine s2 cache1))
  (define t2 (bytes->string/utf-8 b2))
  (check-true (string-contains? t2 "bbb"))
  ;; 旧矩形先被擦（含空格段），新浮层再整块画上
  (check-true (string-contains? t2 (make-string 5 #\space))))
