#lang racket

;; 视口同步（core/editor/sync.rkt）的外部测试。
;; 只同步视口，绝不动选区；锚点 = (行, 显示列)，跨 mode / 跨文档按各自 mode 落位。
(require rackunit
         "../../core-rebuild/editor.rkt"
         "../../core-rebuild/editor/state.rkt"   ; 裸 box setter（适配层用）
         "../../core-rebuild/editor/history.rkt" ; default-history-limit
         (prefix-in c: "../../core-rebuild/editor.rkt")
         "../../core-rebuild/text/document.rkt"
         "../../core-rebuild/text/base/point.rkt"
         "../../core-rebuild/text/base/selection.rkt"
         "../../core-rebuild/text/base/track.rkt"
         "../../core-rebuild/view/base/viewport.rkt"
         "../../core-rebuild/view/base/layout.rkt")

;;; ---------- 焦点 shim（core 不再管焦点） ----------
(define focus (make-parameter 0))
(define (focus-of ed)
  (define f (focus))
  (if (for/or ([v (in-list (editor-views ed))]) (= f (view-id v))) f 0))
(define (editor-open text w h [name "*scratch*"]
                     #:mode [mode 'clip] #:line-numbers? [ln #f]
                     #:chunk-lines [cl default-chunk-lines]
                     #:history-limit [hl default-history-limit] #:history? [hi #t])
  (focus 0)
  (c:editor-open text w h name #:mode mode #:line-numbers? ln
                 #:chunk-lines cl #:history-limit hl #:history? hi))
(define (editor-set-focus ed v) (focus v) ed)
(define (editor-scroll ed d) (editor-view-scroll! ed (focus-of ed) d) ed)
(define (editor-goto ed p) (editor-view-set-point! ed (focus-of ed) p) ed)
(define (editor-set-mode ed m) (editor-view-set-mode! ed (focus-of ed) m) ed)
(define (editor-add-view ed did w h [sync 'free] [link #f] #:mode [m 'clip] #:line-numbers? [ln #f])
  (let-values ([(e _) (c:editor-add-view ed did w h sync link #:mode m #:line-numbers? ln)]) e))

;; adapter：vid 版命令（就地、返回 ed）+ view-with-* / editor-set-view
(define (editor-view-scroll ed vid d) (editor-view-scroll! ed vid d) ed)
(define (editor-view-set-link ed vid l) (editor-view-set-link! ed vid l) ed)
(define (editor-view-set-sync ed vid sy) (editor-view-set-sync! ed vid sy) ed)
(define (editor-sync-viewports ed vid) (editor-sync-viewports! ed vid) ed)
(define (editor-set-view ed v)
  (define cur (editor-view-ref ed (view-id v)))
  (view-set-selections! cur (view-selections v))
  (view-set-viewport! cur (view-viewport v))
  ed)
(define (view-with-selections v s) (make-view (view-id v) (view-did v) (view-viewport v) s (view-sync v) (view-link v)))
(define (view-with-viewport v vp) (make-view (view-id v) (view-did v) vp (view-selections v) (view-sync v) (view-link v)))

(define many (string-join (for/list ([i (in-range 40)]) (format "line ~a" i)) "\n"))

(define (vtl ed vid) (viewport-top-line (view-viewport (editor-view-ref ed vid))))
(define (vlc ed vid) (viewport-left-col (view-viewport (editor-view-ref ed vid))))
(define (vts ed vid) (viewport-top-seg (view-viewport (editor-view-ref ed vid))))
(define (vsels ed vid) (view-selections (editor-view-ref ed vid)))

;; ---------- 同文档 follow：滚动跟随 ----------
(define e0 (editor-open many 20 5))                     ; vid0，focus
(define e1 (editor-add-view e0 0 20 5 'follow))         ; vid1 follow（光标在 (0,0)）
(define e2 (editor-add-view e1 0 20 5 'free))           ; vid2 free
(define e3 (editor-scroll e2 6))
(check-equal? (vtl e3 0) 6)                             ; 发起视图
(check-equal? (vtl e3 1) 6)                             ; follow 跟随（虽光标在 (0,0)）
(check-equal? (vtl e3 2) 0)                             ; free 不动

;; ---------- 编辑 / 导航 ensure 后同步 ----------
(define e4 (editor-goto e1 (point 12 0)))               ; 高 5 → top = 8
(check-equal? (vtl e4 0) 8)
(check-equal? (vtl e4 1) 8)

;; ---------- 跨文档 link ----------
;; 可变绑定下 view 对象会被就地改，跨小节要开新的 base。
(define-values (d1 did1) (editor-add-document (editor-open many 20 5) "aaa\nbbb\nccc"))
(define e5 (editor-add-view d1 did1 20 5))              ; vid1 看 doc1
(define e6 (editor-view-set-link e5 0 'g))
(define e7 (editor-view-set-link e6 1 'g))
(define e8 (editor-scroll e7 2))
(check-equal? (vtl e8 0) 2)                             ; doc0
(check-equal? (vtl e8 1) 2)                             ; doc1 同步到同行号
(check-equal? (view-link (editor-view-ref e8 1)) 'g)

;; 不同 link 键不互相同步
(define e9 (editor-view-set-link e8 1 'other))
(check-equal? (vtl (editor-scroll e9 1) 1) 2)           ; vid0 走 2→3；vid1 留在 2

;; ---------- 混合 mode：clip 锚（显示列）→ wrap 段 ----------
(define m0 (editor-open "abcdefghij\nsecond line here" 6 3))
(define m1 (editor-add-view m0 0 6 3 'follow))          ; vid1 follow
(define m2 (editor-set-mode (editor-set-focus m1 1) 'wrap))   ; vid1 wrap
(define m3 (editor-set-focus m2 0))                     ; 回到 vid0（clip）
(define tl (document-text (editor-view-document m3 0)))
(define lv (editor-view-ref m3 0))
(define m4 (editor-set-view m3 (view-with-viewport lv
                               (viewport-set-left-col tl (view-viewport lv) 7))))
(define m5 (editor-sync-viewports m4 0))
(check-equal? (vlc m5 0) 7)                             ; leader 保留 left-col
(check-equal? (vts m5 1) 1)                             ; follower wrap 段 1（列 7 在 6..10）

;; ---------- 混合 mode：wrap 锚（段起点列）→ clip ----------
(define m6 (editor-view-set-sync m5 0 'follow))         ; vid0 也 follow
(define m7 (editor-sync-viewports m6 1))               ; 以 wrap 视图（段 1 = 列 6）为发起者
(check-equal? (vts m7 1) 1)
(check-equal? (vlc m7 0) 6)                             ; clip 跟随者拿到段起点列

;; ---------- 同步不动选区 ----------
(define s0 (editor-open "abc\ndef\nghi" 20 5))
(define s1 (editor-add-view s0 0 20 5 'follow))
(define s2 (editor-set-view s1 (view-with-selections
                               (editor-view-ref s1 1) (selections-one (caret (point 2 1))))))
(define s3 (editor-scroll s2 1))
(check-equal? (vsels s3 1) (vsels s2 1))                 ; follow 后选区原样

;; ---------- 跨文档比例映射 ----------
;; 同文档：空顶行上的软滚动列原样保留（不走比例，否则会被抹成 0）
(define qa (editor-open "\nabcdefghij" 20 5))
(define q1 (editor-add-view qa 0 20 5 'follow))
(define q2 (editor-set-view q1
             (let ([lv (editor-view-ref q1 0)])
               (view-with-viewport
                lv
                (viewport-set-left-col (document-text (editor-view-document q1 0))
                                       (view-viewport lv) 5)))))
(define q3 (editor-sync-viewports q2 0))
(check-equal? (vlc q3 0) 5)
(check-equal? (vlc q3 1) 5)                             ; follow 精确保留，不被比例化

;; 跨文档：列按两侧锚行显示宽比例（src 10 宽、left-col 6 → dst 5 宽、left-col 3）
(define pa (editor-open "aaaaaaaaaa\nsecond" 20 5))
(define-values (pb didb) (editor-add-document pa "bbbbb\nsecond line"))
(define p1 (editor-add-view pb didb 20 5))              ; vid1 看 doc1
(define p2 (editor-view-set-link p1 0 'g))
(define p3 (editor-view-set-link p2 1 'g))
(define p4 (editor-set-view p3
             (let ([lv (editor-view-ref p3 0)])
               (view-with-viewport
                lv
                (viewport-set-left-col (document-text (editor-view-document p3 0))
                                       (view-viewport lv) 6)))))
(define p5 (editor-sync-viewports p4 0))
(check-equal? (vlc p5 0) 6)                             ; leader
(check-equal? (vlc p5 1) 3)                             ; round(6 * 5/10)

;; ---------- setter / 校验 ----------
(check-equal? (view-sync (editor-view-ref (editor-view-set-sync e0 0 'follow) 0)) 'follow)
(check-equal? (view-link (editor-view-ref (editor-view-set-link e0 0 'k) 0)) 'k)
(check-exn exn:fail? (lambda () (editor-view-set-sync e0 0 'bad)))
(check-exn exn:fail? (lambda () (editor-add-view e0 0 20 5 'bad)))

(displayln "editor/sync.rkt: all tests passed")
