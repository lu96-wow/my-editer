#lang racket

;;; edit-tui/test/float.rkt —— 浮层（document 浮窗）的绘制与清理
;;;
;;; 浮层 = 一块**不在 layout 树里**的 region（真实 document + view），绘制时作为
;;; deep 更高的 panel 交给 core 合成。所以：
;;;
;;;   · 显示：写浮层文档（set-text-effect / 直接 engine 写），选中行 = 文档光标行 + face；
;;;   · 出现 / 移动 / 消失：全在 core 的 screen 里，擦除和“底下正文画回来”
;;;     由 core 的增量 diff 负责 —— 框架不记任何矩形。
;;;
;;; 这条测试盯的正是“关掉浮层后屏幕残留”（旧实现把浮层当叠加 piece 画，
;;; core 的 diff 看不见它，于是擦不掉）。这里用 render-frame 的纯字节验证。

(require rackunit
         racket/string
         "../base/id.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../effects/engine.rkt"
         "../bootstrap/panel.rkt"
         "../projection/render.rkt"
         "../projection/float.rkt"
         "../../core/view/base/rect.rkt"
         "../../core/editor/ops.rkt"
         "../../core/text/base/point.rkt")

(define did (doc-id 1))
(define vid (view-id 1))
(define rid (region-id 1))
(define frid (region-id 2))
(define fvid (view-id 2))

;;; ════════════════ 夹具：10 行文档 + 一块浮层（文档内容 ZZTOP / ZZBOT） ════════════════

(define (make-world)
  (define engine (make-engine))
  (void (engine-create-doc! engine did "m"
                            (string-join (for/list ([i (in-range 10)])
                                           (string-append "line-" (number->string i) "-abcdefghij"))
                                         "\n")))
  (void (engine-create-view! engine vid did))
  ;; 浮层自己的文档 + view
  (void (engine-create-doc! engine fvid "*float*" "ZZTOP\nZZBOT"))
  (void (engine-create-view! engine fvid fvid))
  (define ws0
    (let* ([ws (workspace-empty)]
           [ws (workspace-add-doc ws did (make-doc-meta "m" #:path "/tmp/m"))]
           [ws (workspace-add-view ws vid (view-meta did (hash)))]
           [ws (workspace-add-region ws rid (region rid (list (view-member vid)) vid 'editor))])
      (struct-copy workspace ws [layout (make-leaf rid)])))
  (define s0 (state-set-focus
              (make-state #:workspace ws0 #:ids (make-id-counter 3 3 3 1)
                          #:window (make-window 12 40))
              vid))
  (values engine s0))

;; 浮层挂上去（锚在编辑器 view 的光标处）
(define (with-float s [anchor vid])
  (state-workspace* s
                    (λ (ws)
                      (workspace-add-float ws (float 'demo frid fvid anchor)))))

(define (frame-1 engine s)
  (define-values (_p _c placements) (project-frame s engine))
  (engine-sync-views! engine placements)
  (let-values ([(cache bytes) (render-frame s engine #f)])
    (values cache bytes)))

(define (frame-n engine s cache)
  (define-values (_p _c placements) (project-frame s engine))
  (engine-sync-views! engine placements)
  (render-frame s engine cache))

(define (text-of b) (bytes->string/utf-8 b))

;;; ════════════════ 1. 浮层是 panel：出现在锚点光标下方 ════════════════

(let-values ([(engine s0) (make-world)])
  (define s1 (with-float s0))
  (define-values (cache1 b1) (frame-1 engine s1))
  (define t1 (text-of b1))
  (check-true (string-contains? t1 "ZZTOP") "浮层第一行")
  (check-true (string-contains? t1 "ZZBOT") "浮层第二行")
  (check-true (string-contains? t1 "┌") "浮层边框")
  ;; 投影：一块 float-panel，矩形落在编辑器内容区里、光标下方
  (define fps (project-floats s1 (make-engine-view engine)))
  (check-equal? (length fps) 1)
  (define r (float-panel-rect (car fps)))
  (check-equal? (float-panel-view (car fps)) fvid)
  (check-true (> (rect-y r) 0))
  (check-true (>= (rect-w r) 5))

;;; ════════════════ 2. 关掉浮层：core 的 diff 必须擦掉它、并恢复底下正文 ════════════════

  (define s2 (state-workspace* s1 (λ (ws) (workspace-remove-float ws 'demo))))
  (define-values (_c2 b2) (frame-n engine s2 cache1))
  (define t2 (text-of b2))
  (check-false (string-contains? t2 "ZZTOP") "浮层文本不能残留")
  (check-false (string-contains? t2 "ZZBOT"))
  ;; 被浮层盖住的正文（line-1 / line-2 之类）要重新出现
  (check-true (string-contains? t2 "line-") "底下正文要画回来"))

;;; ════════════════ 3. 浮层内容变化（写文档）也走 core ════════════════

(let-values ([(engine s0) (make-world)])
  (define s1 (with-float s0))
  (define-values (cache1 _b1) (frame-1 engine s1))
  ;; 改浮层文档的文本（真实 document 写）
  (engine-set-view-text! engine fvid "OTHER\nLINES")
  (define-values (_c2 b2) (frame-n engine s1 cache1))
  (define t2 (text-of b2))
  (check-true (string-contains? t2 "OTHER"))
  (check-false (string-contains? t2 "ZZTOP")))

;;; ════════════════ 4. 移动锚点：浮层跟着光标走；关掉后旧位置恢复 ════════════════

(let-values ([(engine s0) (make-world)])
  (define s1 (with-float s0))
  ;; 先走一帧：view 拿到真实尺寸（否则 cursor 位置按 1×1 视口算）
  (define-values (cache1 _b1) (frame-1 engine s1))
  (define r1 (float-panel-rect (car (project-floats s1 (make-engine-view engine)))))
  ;; 光标下移：浮层矩形跟着动
  (view-set-point! (engine-view-object engine vid) (point 4 0))
  (define r2 (float-panel-rect (car (project-floats s1 (make-engine-view engine)))))
  (check-false (equal? r1 r2) "浮层跟着光标移动")

  ;; 移动后的那一帧
  (define-values (cache2 _b2) (frame-n engine s1 cache1))
  ;; 关掉浮层：旧位置必须被擦、底下正文回来（core 的 diff 负责）
  (define s2 (state-workspace* s1 (λ (ws) (workspace-remove-float ws 'demo))))
  (define-values (_c3 b3) (frame-n engine s2 cache2))
  (define t3 (text-of b3))
  (check-false (string-contains? t3 "ZZTOP") "关掉后不能残留浮层文本")
  (check-true (string-contains? t3 "line-") "旧位置的正文要画回来"))
