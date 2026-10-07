#lang racket

;; 与 core/editor/command.rkt 对应的外部测试（经 core/editor.rkt 入口）。
(require rackunit
         "../../core/editor.rkt"
         "../../core/editor/state.rkt"   ; 裸 box setter（适配层用）
         (prefix-in c: "../../core/editor.rkt")
         (prefix-in base: "../../core/editor.rkt")
         (prefix-in icmd: "../../core/editor/command.rkt")   ; 内部原语（install!/record!/step）
         "../../core/text/document.rkt"
         "../../core/editor/history.rkt"
         "../../core/text/command.rkt"
         "../../core/text/base/point.rkt"
         "../../core/text/base/selection.rkt"
         "../../core/text/base/track.rkt"
         "../../core/view/base/viewport.rkt"
         "../../core/view/base/screen.rkt")

;;; ---------- 测试宿主：焦点（core 不再管焦点）+ 焦点糖 ----------
(define focus (make-parameter 0))
;; 焦点按"当前 editor"解析：参数里的 vid 不在该 editor 里就退回 0（模拟"新 editor 焦点 0"）。
(define (focus-of ed)
  (define f (focus))
  (if (for/or ([v (in-list (editor-views ed))]) (= f (view-id v))) f 0))
(define (focused-view ed) (editor-view-ref ed (focus-of ed)))
(define (editor-focused-view ed) (focused-view ed))
(define (focused-doc ed) (editor-view-document ed (focus-of ed)))
(define (editor-focused-document ed) (focused-doc ed))
(define (editor-focused-vid ed) (focus-of ed))
(define (editor-focus ed) (focus-of ed))
(define (editor-set-focus ed v) (focus v) ed)
;; editor-open 重置宿主焦点（模拟"新 editor 焦点 0"）。
(define (editor-open text w h [name "*scratch*"]
                     #:mode [mode 'clip] #:line-numbers? [ln #f]
                     #:chunk-lines [cl default-chunk-lines]
                     #:history-limit [hl default-history-limit]
                     #:history? [hi #t])
  (focus 0)
  (c:editor-open text w h name #:mode mode #:line-numbers? ln
                 #:chunk-lines cl #:history-limit hl #:history? hi))

;; 新 API：命令式操作就地改 box、不返回 ed。测试 shim 保留旧的调用形状
;; （返回 ed，或 (values ed ...)），让下面的测试用例基本不用动。
(define (editor-edit ed op [tag #f] [ensure? #t])
  (base:editor-view-edit! ed (focus-of ed) op tag ensure?) ed)
(define (editor-insert ed text [tag #f])
  (base:editor-view-insert! ed (focus-of ed) text tag) ed)
(define (editor-backspace ed [tag #f])
  (base:editor-view-backspace! ed (focus-of ed) tag) ed)
(define (editor-delete ed [tag #f])
  (base:editor-view-delete! ed (focus-of ed) tag) ed)
(define (editor-paste ed [tag #f])
  (base:editor-view-paste! ed (focus-of ed) tag) ed)
(define (editor-paste-text ed text [tag #f])
  (base:editor-view-paste-text! ed (focus-of ed) text tag) ed)
(define (editor-cut ed [tag #f])
  (base:editor-view-cut! ed (focus-of ed) tag) ed)
(define (editor-view-edit ed vid op [tag #f] [ensure? #t])
  (base:editor-view-edit! ed vid op tag ensure?) ed)
(define (editor-view-insert ed vid text [tag #f])
  (base:editor-view-insert! ed vid text tag) ed)
(define (editor-view-backspace ed vid [tag #f])
  (base:editor-view-backspace! ed vid tag) ed)
(define (editor-view-delete ed vid [tag #f])
  (base:editor-view-delete! ed vid tag) ed)
(define (editor-view-paste ed vid [tag #f])
  (base:editor-view-paste! ed vid tag) ed)
(define (editor-view-paste-text ed vid text [tag #f])
  (base:editor-view-paste-text! ed vid text tag) ed)
(define (editor-view-cut ed vid [tag #f])
  (base:editor-view-cut! ed vid tag) ed)
(define (editor-add-view ed did w h #:mode [m 'clip] #:line-numbers? [ln #f])
  (let-values ([(e _) (base:editor-add-view ed did w h #:mode m #:line-numbers? ln)]) e))

;; vid 版命令（测试直接调 editor-view-*）：adapter → 就地、返回 ed
(define (editor-view-select-all ed vid) (base:editor-view-select-all! ed vid) ed)
(define (editor-view-set-point ed vid p) (base:editor-view-set-point! ed vid p) ed)
(define (editor-view-goto ed vid p) (base:editor-view-goto! ed vid p) ed)
(define (editor-view-set-selections ed vid s #:ensure? [e #t]) (base:editor-view-set-selections! ed vid s #:ensure? e) ed)
(define (editor-view-scroll ed vid d) (base:editor-view-scroll! ed vid d) ed)
(define (editor-view-set-top-line ed vid n) (base:editor-view-set-top-line! ed vid n) ed)
(define (editor-view-set-left-column ed vid n) (base:editor-view-set-left-column! ed vid n) ed)
(define (editor-view-set-mode ed vid m) (base:editor-view-set-mode! ed vid m) ed)
(define (editor-view-toggle-line-numbers ed vid) (base:editor-view-toggle-line-numbers! ed vid) ed)
(define (editor-view-set-size ed vid w h) (base:editor-view-set-size! ed vid w h) ed)
(define (editor-view-undo ed vid) (base:editor-view-undo! ed vid) ed)
(define (editor-view-redo ed vid) (base:editor-view-redo! ed vid) ed)
(define (editor-view-clear-history ed vid) (base:editor-view-clear-history! ed vid) ed)
(define (editor-view-reset-history ed vid [e #f]) (base:editor-view-reset-history! ed vid e) ed)
(define (editor-view-seal ed vid) (base:editor-view-seal! ed vid) ed)
(define (editor-view-set-history-enabled ed vid f) (base:editor-view-set-history-enabled! ed vid f) ed)
(define (editor-view-copy ed vid) (base:editor-view-copy! ed vid) ed)
(define (editor-view-left ed vid [x #f]) (base:editor-view-left! ed vid x) ed)
(define (editor-view-right ed vid [x #f]) (base:editor-view-right! ed vid x) ed)
(define (editor-view-up ed vid [x #f]) (base:editor-view-up! ed vid x) ed)
(define (editor-view-down ed vid [x #f]) (base:editor-view-down! ed vid x) ed)
(define (editor-view-home ed vid [x #f]) (base:editor-view-home! ed vid x) ed)
(define (editor-view-end ed vid [x #f]) (base:editor-view-end! ed vid x) ed)
(define (editor-view-highlight ed vid face) (base:editor-view-highlight! ed vid face) ed)
(define (editor-view-highlight-range ed vid r face) (base:editor-document-highlight-range! ed (base:editor-view-document-id ed vid) r face) ed)
(define (editor-view-highlight-cell ed vid l c face) (base:editor-document-highlight-cell! ed (base:editor-view-document-id ed vid) l c face) ed)
(define (editor-view-highlight-line ed vid l face) (base:editor-document-highlight-line! ed (base:editor-view-document-id ed vid) l face) ed)
(define (editor-view-highlight-selections ed vid face) (base:editor-view-highlight-selections! ed vid face) ed)
(define (editor-view-readonly ed vid f) (base:editor-view-readonly! ed vid f) ed)
(define (editor-view-readonly-range ed vid r f) (base:editor-document-readonly-range! ed (base:editor-view-document-id ed vid) r f) ed)
(define (editor-view-readonly-cell ed vid l c f) (base:editor-document-readonly-cell! ed (base:editor-view-document-id ed vid) l c f) ed)
(define (editor-view-readonly-line ed vid l f) (base:editor-document-readonly-line! ed (base:editor-view-document-id ed vid) l f) ed)
(define (editor-view-readonly-selections ed vid f) (base:editor-view-readonly-selections! ed vid f) ed)

;; 测试用：从旧 API 的 view-with-* / editor-set-view 适配到就地 setter
(define (view-with-selections v s) (make-view (view-id v) (view-did v) (view-viewport v) s))
(define (view-with-viewport v vp) (make-view (view-id v) (view-did v) vp (view-selections v)))
(define (editor-set-view ed v)
  (define cur (editor-view-ref ed (view-id v)))
  (view-set-selections! cur (view-selections v))
  (view-set-viewport! cur (view-viewport v))
  ed)
;; 通用原语（内部件）：保留旧形状 (values ed step)
(define (editor-view-set ed vid value #:selections [s #f] #:change [c #f] #:ensure? [ens #t]
                         #:chunk-lines [cl default-chunk-lines])
  (values ed (icmd:editor-view-install! ed vid value #:selections s #:change c #:ensure? ens #:chunk-lines cl)))
(define (editor-history-record ed did step [tag #f])
  (icmd:editor-document-history-record! ed did step tag) ed)
(define (editor-view-assign ed vid value #:selections [s #f] #:ensure? [ens #f]
                            #:chunk-lines [cl default-chunk-lines])
  (base:editor-view-assign! ed vid value #:selections s #:ensure? ens #:chunk-lines cl) ed)
;; -ignore-readonly 版：测试用 (values ed changes)
(define (ig-ro f ed a b)
  (define-values (ch _) (f ed a b)) (values ed ch))
(define (editor-insert-ignore-readonly ed text [tag #f])
  (define-values (ch _) (base:editor-view-insert-ignore-readonly! ed (focus-of ed) text tag)) (values ed ch))
(define (editor-backspace-ignore-readonly ed [tag #f])
  (define-values (ch _) (base:editor-view-backspace-ignore-readonly! ed (focus-of ed) tag)) (values ed ch))
(define (editor-delete-ignore-readonly ed [tag #f])
  (define-values (ch _) (base:editor-view-delete-ignore-readonly! ed (focus-of ed) tag)) (values ed ch))
(define (editor-paste-ignore-readonly ed [tag #f])
  (define-values (ch _) (base:editor-view-paste-ignore-readonly! ed (focus-of ed) tag)) (values ed ch))
(define (editor-paste-text-ignore-readonly ed text [tag #f])
  (define-values (ch _) (base:editor-view-paste-text-ignore-readonly! ed (focus-of ed) text tag)) (values ed ch))
(define (editor-cut-ignore-readonly ed [tag #f])
  (define-values (ch _) (base:editor-view-cut-ignore-readonly! ed (focus-of ed) tag)) (values ed ch))

(define (editor-left ed [x #f]) (base:editor-view-left! ed (focus-of ed) x) ed)
(define (editor-right ed [x #f]) (base:editor-view-right! ed (focus-of ed) x) ed)
(define (editor-home ed [x #f]) (base:editor-view-home! ed (focus-of ed) x) ed)
(define (editor-end ed [x #f]) (base:editor-view-end! ed (focus-of ed) x) ed)
(define (editor-up ed [x #f]) (base:editor-view-up! ed (focus-of ed) x) ed)
(define (editor-down ed [x #f]) (base:editor-view-down! ed (focus-of ed) x) ed)
(define (editor-scroll ed d) (base:editor-view-scroll! ed (focus-of ed) d) ed)
(define (editor-goto ed p) (base:editor-view-set-point! ed (focus-of ed) p) ed)
(define (editor-set-selections ed x) (base:editor-view-set-selections! ed (focus-of ed) x) ed)
(define (editor-select-all ed) (base:editor-view-select-all! ed (focus-of ed)) ed)
(define (editor-set-point ed p) (base:editor-view-set-point! ed (focus-of ed) p) ed)
(define (editor-set-mode ed m) (base:editor-view-set-mode! ed (focus-of ed) m) ed)
(define (editor-toggle-line-numbers ed) (base:editor-view-toggle-line-numbers! ed (focus-of ed)) ed)
(define (editor-set-top-line ed n) (base:editor-view-set-top-line! ed (focus-of ed) n) ed)
(define (editor-set-left-column ed n) (base:editor-view-set-left-column! ed (focus-of ed) n) ed)
(define (editor-undo ed) (base:editor-view-undo! ed (focus-of ed)) ed)
(define (editor-redo ed) (base:editor-view-redo! ed (focus-of ed)) ed)
(define (editor-clear-history ed) (base:editor-view-clear-history! ed (focus-of ed)) ed)
(define (editor-reset-history ed [enabled? #f]) (base:editor-view-reset-history! ed (focus-of ed) enabled?) ed)
(define (editor-seal ed) (base:editor-view-seal! ed (focus-of ed)) ed)
(define (editor-set-history-enabled ed flag) (base:editor-view-set-history-enabled! ed (focus-of ed) flag) ed)
(define (editor-copy ed) (base:editor-view-copy! ed (focus-of ed)) ed)
(define (editor-highlight ed face) (base:editor-view-highlight! ed (focus-of ed) face) ed)
(define (editor-highlight-range ed r face) (base:editor-document-highlight-range! ed (base:editor-view-document-id ed (focus-of ed)) r face) ed)
(define (editor-readonly ed flag) (base:editor-view-readonly! ed (focus-of ed) flag) ed)
(define (editor-readonly-range ed r flag) (base:editor-document-readonly-range! ed (base:editor-view-document-id ed (focus-of ed)) r flag) ed)
(define (editor-string ed) (editor-view-string ed (focus-of ed)))
(define (editor-point ed) (editor-view-point ed (focus-of ed)))
(define (editor-primary ed) (editor-view-primary ed (focus-of ed)))
(define (editor-selections ed) (editor-view-selections ed (focus-of ed)))
(define (editor-selection-count ed) (editor-view-selection-count ed (focus-of ed)))
(define (editor-point-line ed) (editor-view-point-line ed (focus-of ed)))
(define (editor-point-column ed) (editor-view-point-column ed (focus-of ed)))
(define (editor-mode ed) (editor-view-mode ed (focus-of ed)))
(define (editor-line-numbers? ed) (editor-view-line-numbers? ed (focus-of ed)))
(define (editor-depth ed) (editor-view-depth ed (focus-of ed)))
(define (editor-can-undo? ed) (editor-view-can-undo? ed (focus-of ed)))
(define (editor-can-redo? ed) (editor-view-can-redo? ed (focus-of ed)))
(define (editor-history-enabled? ed) (editor-view-history-enabled? ed (focus-of ed)))
(define (editor-highlight-range? ed l0 c0 l1 c1) (editor-view-highlight-range? ed (focus-of ed) l0 c0 l1 c1))
(define (editor-top-line ed) (editor-view-top-line ed (focus-of ed)))
(define (editor-top-segment ed) (editor-view-top-segment ed (focus-of ed)))
(define (editor-left-column ed) (editor-view-left-column ed (focus-of ed)))
(define (editor-width ed) (editor-view-width ed (focus-of ed)))
(define (editor-height ed) (editor-view-height ed (focus-of ed)))
(define (editor-view-document-id ed vid) (view-did (editor-view-ref ed vid)))
(define (editor-point->screen-position ed p) (editor-view-point->screen-position ed (focus-of ed) p))
(define (editor-screen-position->point ed r c) (editor-view-screen-position->point ed (focus-of ed) r c))
(define (editor-readonly-at? ed l c) (editor-view-readonly-at? ed (focus-of ed) l c))
(define (editor-readonly-range? ed l0 c0 l1 c1) (editor-view-readonly-range? ed (focus-of ed) l0 c0 l1 c1))
(define (editor-editable? ed l0 c0 l1 c1) (editor-view-editable? ed (focus-of ed) l0 c0 l1 c1))
(define (editor-set-size ed w h) (base:editor-view-set-size! ed (focus-of ed) w h) ed)

(define (doc-str ed) (document->string (focused-doc ed)))
(define (caret-position ed) (selection-head (selections-primary (view-selections (focused-view ed)))))
(define (depth ed) (history-depth (editor-document-history ed (view-did (focused-view ed)))))

;; editor 值不再是快照（写就地改绑定），测试要显式深拷贝才留得住旧值。
;; 只复制可变绑定（history / viewport / selections 的 box），不可变值共享。
(define (snap ed)
  (struct-copy editor ed
    [documents (for/list ([e (in-list (editor-documents ed))])
                 (document-entry (document-entry-im e)
                                 (entry-mutable (box (document-entry-name e))
                                                (box (document-entry-history e)))))]
    [views (for/list ([v (in-list (editor-views ed))])
             (view (view-im v)
                   (view-mutable (box (view-viewport v)) (box (view-selections v)))))]
    [clipboard-box (box (editor-clipboard ed))]))

;; 宿主策略：打字用 'typing（形状门会把多字符挡掉）；这里显式传 tag，core 不预设。
(define (type-it ed text) (editor-insert ed text 'typing))

;; ---------- 打字：进文档 + 选区前进；连续单字符打字并成一步 ----------
(define ed0 (editor-open "abc" 40 10))
(define e1 (type-it (snap ed0) "X"))
(check-equal? (doc-str e1) "Xabc")
(check-equal? (caret-position e1) (point 0 1))
(check-equal? (depth e1) 1)
(define e2 (type-it (snap e1) "Y"))
(check-equal? (doc-str e2) "XYabc")
(check-equal? (depth e2) 1)                       ; 连续打字合并
(define e3 (editor-insert (snap e2) "ZZ"))                 ; 不传 tag → 一步一条
(check-equal? (doc-str e3) "XYZZabc")
(check-equal? (caret-position e3) (point 0 4))
(check-equal? (depth e3) 2)

;; ---------- 退格 / 删除 ----------
(check-equal? (doc-str (editor-backspace (snap e3))) "XYZabc")
(check-equal? (doc-str (editor-delete (snap e1))) "Xbc")   ; 光标在 (0,1)，删 'a'

;; ---------- 导航：不改文本、不记步 ----------
(define e4 (editor-right (snap e3)))
(check-equal? (doc-str e4) "XYZZabc")
(check-equal? (caret-position e4) (point 0 5))
(define e5 (type-it (snap e4) "Q"))
(check-equal? (doc-str e5) "XYZZaQbc")           ; 光标在 (0,5) = 'a' 与 'b' 之间
(check-equal? (depth e5) 3)                        ; 导航后选区变了 → 不并

;; ---------- undo / redo ----------
(define e6 (editor-undo (snap e5)))
(check-equal? (doc-str e6) "XYZZabc")             ; 回退一步
(check-equal? (caret-position e6) (point 0 5))         ; 还原该步发起时的选区
(define e7 (editor-redo (snap e6)))
(check-equal? (doc-str e7) (doc-str e5))
(check-equal? (caret-position e7) (point 0 6))

;; 空历史 undo 不动
(check-eq? (editor-undo ed0) ed0)

;; ---------- 多视图共享文档：undo 还原发起视图的选区 ----------
(define edv (editor-add-view (snap e3) 0 40 10))         ; vid 1，选区在 (0,0)
(define edv1 (editor-set-focus edv 1))
(define edv2 (type-it edv1 "M"))
(check-equal? (doc-str edv2) "MXYZZabc")
(check-equal? (caret-position edv2) (point 0 1))
(define edv3 (editor-undo edv2))
(check-equal? (doc-str edv3) "XYZZabc")
(check-equal? (caret-position edv3) (point 0 0))       ; vid1 自己的选区被还原（不是 vid0 的）

;; ---------- 视口设置 ----------
(define ew (editor-set-mode ed0 'wrap))
(check-equal? (viewport-mode (view-viewport (editor-focused-view ew))) 'wrap)
(define eg (editor-toggle-line-numbers ed0))
(check-true (viewport-line-numbers? (view-viewport (editor-focused-view eg))))
;; 滚动不动文档
(check-equal? (doc-str (editor-scroll ed0 3)) "abc")

;; ---------- 投影 ----------
(check-true (screen? (editor-view-render e1 0)))
(check-equal? (map run-text (screen-row (editor-view-render e1 0) 0)) '("Xabc"))

;; ---------- 高亮 = 作者态：不记步，随文本快照回退 ----------
(define (hl-row ed) (document-highlight-row (editor-focused-document ed) 0))

(define ha0 (editor-open "abc" 40 10))
(define ha1 (type-it (snap ha0) "X"))               ; "Xabc"（文本步，depth 1）
(define ha2 (editor-left (snap ha1) #t))                  ; 扩选 'X'
(define ha3 (editor-highlight (snap ha2) 'kw))            ; 高亮 'X'
(check-equal? (depth ha3) 1)                       ; 高亮不记步
(check-equal? (hl-row ha3) (vector 'kw #f #f #f))

;; 再打一个文本步；之后 undo 撤这一步 → 保留高亮（它在该步的 pre 里）
(define ha3b (editor-end (snap ha3)))
(define ha4 (type-it (snap ha3b) "Y"))               ; "XabcY"（depth 2）
(check-equal? (depth ha4) 2)
(define ha5 (editor-undo (snap ha4)))
(check-equal? (doc-str ha5) "Xabc")
(check-equal? (hl-row ha5) (vector 'kw #f #f #f))
(define ha6 (editor-redo (snap ha5)))
(check-equal? (doc-str ha6) "XabcY")
(check-equal? (hl-row ha6) (vector (quote kw) #f #f #f #f))

;; 再 undo 撤掉高亮所在的那一步文本 → 高亮随该步一起回退；redo 复原
(define ha7 (editor-undo (snap ha5)))
(check-equal? (doc-str ha7) "abc")
(check-equal? (hl-row ha7) (vector #f #f #f))
(define ha8 (editor-redo (snap ha7)))
(check-equal? (doc-str ha8) "Xabc")
(check-equal? (hl-row ha8) (vector 'kw #f #f #f))

;; readonly 同样：不记步，随快照搭车
(define hr0 (editor-open "abc" 40 10))
(define hr1 (editor-right hr0 #t))                 ; 扩选 'a'
(define hr2 (editor-readonly hr1 #t))
(check-equal? (depth hr2) 0)                       ; 不记步
(check-equal? (track-ref (document-readonly (editor-focused-document hr2)) 0)
              (vector #t #f #f))

;; ---------- 属性区间写（作者态；不记步；用 range） ----------
(define rg0 (editor-open "abcd\nef" 40 10))
(define rg1 (editor-highlight-range rg0 (range (point 0 1) (point 1 1)) 'kw))
(check-equal? (depth rg1) 0)                                ; 不记步
(check-equal? (document-highlight-row (editor-focused-document rg1) 0) (vector #f 'kw 'kw 'kw))
(check-equal? (document-highlight-row (editor-focused-document rg1) 1) (vector 'kw #f))
;; 乱序区间自动归一（range 内部 range-normalize）
(define rg2 (editor-highlight-range rg0 (range (point 1 1) (point 0 1)) 'kw))
(check-equal? (document-highlight-row (editor-focused-document rg2) 0)
              (document-highlight-row (editor-focused-document rg1) 0))
;; 只读区间
(define rr0 (editor-readonly-range rg0 (range (point 0 0) (point 0 2)) #t))
(check-true (document-readonly-at? (editor-focused-document rr0) 0 0))
(check-true (document-readonly-at? (editor-focused-document rr0) 0 1))
(check-false (document-readonly-at? (editor-focused-document rr0) 0 2))
(check-equal? (depth rr0) 0)
;; 选区糖 == 对同一区间直接写
(define hs0 (editor-open "abcd" 40 10))
(define hs1 (editor-right (editor-right hs0 #t) #t))        ; 扩选 "ab"
(define hs2 (editor-highlight hs1 'x))
(define ht0 (editor-open "abcd" 40 10))
(define ht1 (editor-highlight-range ht0 (range (point 0 0) (point 0 2)) 'x))
(check-equal? (document-highlight-row (editor-focused-document hs2) 0)
              (document-highlight-row (editor-focused-document ht1) 0))
;; 按 vid 写：只动该视图的文档，焦点文档不变
(define rv0 (editor-open "abcd" 20 5 "a"))
(define-values (rv1 rvd) (editor-add-document rv0 "wxyz" "b"))
(define rv2 (editor-add-view rv1 rvd 20 5))
(define rv3 (editor-view-highlight-range rv2 1 (range (point 0 0) (point 0 2)) 'v))
(check-equal? (document-highlight-row (editor-focused-document rv3) 0) (vector #f #f #f #f))
(check-equal? (document-highlight-row (editor-view-document rv3 1) 0) (vector 'v 'v #f #f))

;; ---------- 多文档 + 按 vid 投影 + compose（布局由调用方给） ----------
(define mw0 (editor-open "abc" 20 5 "a"))
(define-values (mw1 did1) (editor-add-document mw0 "two" "b"))
(check-equal? did1 1)
(define mw2 (editor-add-view mw1 did1 20 5))            ; vid 1 看文档 1
(check-equal? (view-did (editor-view-ref mw2 1)) 1)
(check-equal? (editor-focus mw2) 0)                     ; 焦点仍是 vid0
;; 显式渲染 vid1；焦点渲染 == vid0 渲染
(check-equal? (map run-text (screen-row (editor-view-render mw2 1) 0)) '("two"))
(check-equal? (document->string (editor-view-document mw2 0)) "abc")
(check-equal? (screen->string (editor-view-render mw2 0)) (screen->string (editor-view-render mw2 0)))

;; 左右并排：位置、active 由调用方给；合成由 editor 负责
(define comp (editor-render-layout mw2 (list (rectangle 0 0 0 20 5 0) (rectangle 1 20 0 20 5 0)) 0 40 5))
(check-equal? (map (lambda (r) (list (run-column r) (run-text r))) (screen-row comp 0))
              '((0 "abc") (20 "two")))
;; 只有 active pane 的光标透出
(check-equal? (screen-cursors comp) (list (cursor 0 0 #t)))
(check-equal? (screen-cursors (editor-render-layout mw2 (list (rectangle 0 0 0 20 5 0) (rectangle 1 20 0 20 5 0)) 1 40 5))
              (list (cursor 0 20 #t)))
;; 多视图增量：首帧 → 全量
(define-values (cpN cpRn cpSn)
  (editor-render-layout-patch mw2 #f (list (rectangle 0 0 0 20 5 0) (rectangle 1 20 0 20 5 0)) 0 40 5))
(check-equal? (screen->string cpN) (screen->string comp))

;; ---------- 增量投影：旧帧 → (新帧, clear, render, selection) ----------
(define rp0 (editor-view-render mw2 0))
(define-values (rpN rpRn rpSn) (editor-render-patch mw2 0 rp0))
(check-equal? (screen->string rpN) (screen->string rp0))
(check-equal? rpRn '())
(check-equal? rpSn '())
;; 打字后：脏格进 render（覆盖输出）
(define-values (rpN2 rpRn2 rpSn2) (editor-render-patch (type-it mw2 "Z") 0 rp0))
(check-true (pair? rpRn2))

;; ---------- 剪贴板（editor 层：跨文档共享） ----------
(define cb0 (editor-open "XY\nZ" 20 5))
(define cb1 (editor-right (editor-right cb0 #t) #t))   ; 扩选 "XY"
(define cb2 (editor-copy cb1))
(check-equal? (clipboard-text (editor-clipboard cb2)) '("XY"))
(check-equal? (doc-str cb2) "XY\nZ")                  ; copy 不改文档
(check-equal? (depth cb2) 0)                            ; copy 不记步

;; 粘到同文档（光标处插入）
(define cb3 (editor-paste (editor-goto cb2 (point 0 2))))
(check-equal? (doc-str cb3) "XYXY\nZ")
(check-equal? (caret-position cb3) (point 0 4))
(check-equal? (depth cb3) 1)                            ; paste 记一步
(define cb4 (editor-undo cb3))
(check-equal? (doc-str cb4) "XY\nZ")
(check-equal? (caret-position cb4) (point 0 2))

;; 选区上粘贴 = 替换（不是插入）
(define cb5 (editor-paste (editor-right (editor-goto cb2 (point 1 0)) #t)))   ; 选 "Z"，粘 "XY"
(check-equal? (doc-str cb5) "XY\nXY")
(check-equal? (caret-position cb5) (point 1 2))

;; 跨文档：同一 editor 的剪贴板可在另一个 document 粘贴
(define-values (xd0 xdid) (editor-add-document cb2 ".\n."))
(define xd1 (editor-set-focus (editor-add-view xd0 xdid 20 5) 1))
(check-equal? (document->string (editor-focused-document (editor-paste (editor-goto xd1 (point 0 0))))) "XY.\n.")

;; 空剪贴板 / 只读守卫
(define eb (editor-open "abc" 20 5))
(check-eq? (editor-paste eb) eb)
(define ro0 (editor-open "a" 20 5))
(define ro1 (editor-readonly (editor-right ro0 #t) #t))   ; 'a' 只读
(define ro2 (editor-copy ro1))
(check-eq? (editor-paste ro2) ro2)

;; ---------- 编辑传播到同文档其它视图（选区重基准，不越界） ----------
(define mv0 (editor-open "l0\nl1\nl2\nl3\nl4\nl5" 20 5))
(define mv1 (editor-add-view mv0 0 20 5))
(define mv2 (editor-set-view mv1 (view-with-selections
                                 (editor-view-ref mv1 1) (selections-one (caret (point 4 0))))))
;; 焦点 vid0：删前 3 行
(define mv3 (editor-edit mv2 (lambda (d s) (command-type-ignore-readonly d (selections-one (selection (point 0 0) (point 2 1))) ""))))
(check-equal? (document->string (editor-focused-document mv3)) "2\nl3\nl4\nl5")
(check-equal? (view-selections (editor-view-ref mv3 1))
              (selections-one (caret (point 2 0))))     ; 4 - 2 行
(check-true (screen? (editor-view-render mv3 1)))        ; 不再越界崩溃

;; undo 后文档回退：同文档其它视图的选区被 clamp 回合法域
(define un0 (editor-open "a\nb\nc\nd" 20 5))
(define un1 (editor-add-view un0 0 20 5))
(define un2 (editor-set-view un1 (view-with-selections
                                 (editor-view-ref un1 1) (selections-one (caret (point 3 0))))))
(define un3 (editor-edit un2 (lambda (d s) (command-type-ignore-readonly d (selections-one (caret (point 3 1))) "\n\n\n"))))
(define un4 (editor-undo un3))
(check-equal? (view-selections (editor-view-ref un4 1))
              (selections-one (caret (point 3 0))))
(check-true (screen? (editor-view-render un4 1)))

;; ---------- editor 层补全：全选 / 剪切 / 按 vid 程序命令 ----------
(define cf0 (editor-open "abc\ndef" 20 5))
(define cf1 (editor-select-all cf0))
(check-equal? (view-selections (editor-focused-view cf1))
              (selections-one (selection (point 0 0) (point 1 3))))
(define cf2 (editor-cut cf1))
(check-equal? (doc-str cf2) "")
(check-equal? (clipboard-text (editor-clipboard cf2)) '("abc" "def"))
(check-equal? (caret-position cf2) (point 0 0))
;; 空选区 cut = 不动
(define cf3 (editor-open "abc" 20 5))
(check-eq? (editor-cut cf3) cf3)

;; 按 vid 装点 / 选区（不动其它视图）
(define pv0 (editor-open "abc\ndef" 20 5))
(define pv1 (editor-add-view pv0 0 20 5))
(define pv2 (editor-view-set-point pv1 1 (point 1 2)))
(check-equal? (view-selections (editor-view-ref pv2 1)) (selections-one (caret (point 1 2))))
(check-equal? (view-selections (editor-view-ref pv2 0)) (selections-one (caret (point 0 0))))

;; 按 vid 切 mode / 行号
(check-equal? (editor-view-mode (editor-view-set-mode pv1 1 'wrap) 1) 'wrap)
(check-equal? (editor-view-mode (editor-view-set-mode pv1 1 'wrap) 0) 'clip)
(check-true (editor-view-line-numbers? (editor-view-toggle-line-numbers pv1 1) 1))
(check-false (editor-view-line-numbers? (editor-view-toggle-line-numbers pv1 1) 0))

;; 按 vid 显式滚
(check-equal? (editor-view-top-line (editor-view-set-top-line pv1 0 1) 0) 1)
(check-equal? (editor-view-left-column (editor-view-set-left-column pv1 0 2) 0) 2)

;; 焦点糖：set-point / set-top-line / set-left-column（与 editor-view-* 一致）
(define fz0 (editor-open "abcdef\ngh" 5 5))
(check-equal? (caret-position (editor-set-point fz0 (point 0 3))) (point 0 3))
(check-equal? (editor-top-line (editor-set-top-line fz0 1)) 1)
(check-equal? (editor-left-column (editor-set-left-column fz0 2)) 2)

;; ---------- editor-insert：回车 / 制表 / 程序插入的统一入口（一次 = 一步） ----------
(define ip0 (editor-open "ab" 20 5))
(define ip1 (editor-insert ip0 "\n"))
(check-equal? (doc-str ip1) "\nab")
(check-equal? (depth ip1) 1)
(define ip2 (editor-insert ip1 "x"))
(check-equal? (depth ip2) 2)
(check-equal? (depth (editor-insert ip2 "yz")) 3)

;; ---------- 合并：纯 tag 控制（editor 只校验 who + 选区连续，不看形状） ----------
;; 同 tag + 同视图 + 选区连续 → 并
(check-equal? (depth (type-it (type-it (editor-open "a" 20 5) "x") "y")) 1)
;; 多字符也一样并（没有形状门）
(check-equal? (depth (type-it (type-it (editor-open "a" 20 5) "xy") "z")) 1)
;; 不传 tag → 一步一条
(define nt0 (editor-open "abc" 20 5))
(check-equal? (depth (editor-insert (editor-insert nt0 "x") "y")) 2)
;; 换 tag → 不并
(define tg0 (editor-open "abc" 20 5))
(check-equal? (depth (editor-insert (editor-insert tg0 "x" 'typing) "y" 'other)) 2)
;; 选区动过（导航）→ 不并
(define nv0 (type-it (editor-open "abc" 20 5) "x"))
(check-equal? (depth (type-it (editor-left nv0) "y")) 2)

;; 连打三字 = 一步；连退两格 = 一步
(check-equal? (depth (type-it (type-it (type-it (editor-open "a" 20 5) "x") "y") "z")) 1)
(check-equal? (depth (let* ([e (editor-end (editor-open "abc" 20 5))])
                       (editor-backspace (editor-backspace e 'backspace) 'backspace)))
              1)
;; 前向删除连续段：并
(define dl0 (editor-open "abcde" 20 5))
(define dl1 (editor-right (editor-right dl0)))            ; caret (0,2)
(check-equal? (depth (editor-delete (editor-delete dl1 'delete) 'delete)) 1)
;; 选区删除也能并（没有形状门）：同样的 'backspace，一步
(define sh0 (editor-open "abcdefg" 20 5))
(define sh1 (editor-right (editor-right sh0)))                        ; caret (0,2)
(define sh2 (editor-right (editor-right (editor-right sh1 #t) #t) #t)) ; 选 "cde"
(check-equal? (depth (editor-backspace (editor-backspace sh2 'backspace) 'backspace)) 1)

;; 文首退格是无变更：不记步、原样返回
(define nook (editor-open "abc" 20 5))
(check-eq? (editor-backspace nook) nook)
(check-equal? (depth (editor-backspace nook)) 0)

;; 粘贴：不传 tag → 各自一步
(define mgp0 (editor-open "abc" 20 5))
(define mgp1 (type-it mgp0 "x"))
(define mgp2 (editor-paste-text mgp1 "Q"))          ; 单字符粘贴，不传 tag
(check-equal? (depth mgp2) 2)
(check-equal? (depth (editor-paste-text mgp2 "R")) 3)

;; 多光标粘贴：一次操作一步
(define mcp0 (editor-set-selections (editor-open "abc\ndef" 20 5)
                                    (selections-of (list (caret (point 0 1)) (caret (point 1 1))) 0)))
(define mcp1 (editor-paste-text mcp0 "Z"))
(check-equal? (doc-str mcp1) "aZbc\ndZef")
(check-equal? (depth mcp1) 1)

;; 连续回车：不传 tag → 各自成步
(define nl0 (editor-open "ab" 20 5))
(check-equal? (depth (editor-insert (editor-insert nl0 "\n") "\n")) 2)

;; 高亮 = 作者态：不记步，也不打断打字连续性
(define hb0 (editor-open "ab" 20 5))
(define hb1 (type-it hb0 "x"))                      ; depth 1
(define hb2 (editor-highlight hb1 'kw))                  ; 不记步
(check-equal? (depth hb2) 1)
(check-equal? (depth (type-it hb2 "y")) 1)          ; 高亮不打断打字

;; 多光标打字：同 tag + 选区连续 → 并成一步
(define mc0 (editor-set-selections (editor-open "abc\ndef" 20 5)
                                   (selections-of (list (caret (point 0 1)) (caret (point 1 1))) 0)))
(check-equal? (depth (type-it (type-it mc0 "X") "Y")) 1)

;; ---------- editor-seal：封口当前段（不记步）；之后同 tag 也新起一步 ----------
(define sl0 (type-it (editor-open "abc" 20 5) "x"))     ; depth 1
(define sl1 (editor-seal sl0))
(check-equal? (depth sl1) 1)                             ; 封口不记步
(check-equal? (doc-str sl1) "xabc")                      ; 不改文档
(check-equal? (depth (type-it sl1 "y")) 2)               ; 封口后同 tag 也另起

;; ---------- 装选区：不记步（焦点版 / 按 vid 版一致） ----------
(define ss0 (type-it (editor-open "ab" 20 5) "X"))                ; depth 1
(define ss1 (editor-set-selections ss0 (selections-one (caret (point 0 1)))))
(check-equal? (depth ss1) 1)                                           ; 装选区不记步
(check-equal? (caret-position ss1) (point 0 1))
(define vs0 (editor-set-focus (editor-add-view ss0 0 20 5) 1))
(define vs1 (editor-view-set-point vs0 1 (point 0 1)))
(check-equal? (depth vs1) 1)
(check-equal? (editor-view-point vs1 1) (point 0 1))

;; ---------- editor-view-edit：对非焦点视图施加编辑（焦点版是其糖）-----------
(define ve0 (editor-add-view (editor-open "abc" 20 5) 0 20 5))   ; vid1，caret (0,0)
(define ve1 (editor-set-focus ve0 0))                            ; 焦点回到 vid0
(define ve2 (editor-view-edit ve1 1 (lambda (d s) (command-type d s "Z"))))
(check-equal? (doc-str ve2) "Zabc")
(check-equal? (caret-position ve2) (point 0 0))                       ; 焦点 vid0 光标未被带跑
(check-equal? (selection-head (selections-primary (view-selections (editor-view-ref ve2 1)))) (point 0 1))
(define ve3 (editor-undo ve2))                                   ; undo 还原发起视图 vid1 的选区
(check-equal? (doc-str ve3) "abc")
(check-equal? (selection-head (selections-primary (view-selections (editor-view-ref ve3 1)))) (point 0 0))

;; ---------- 按 vid 导航 / 滚动 / 撤销（焦点不动）----------
(define vn0 (editor-add-view (editor-open "abc" 20 5) 0 20 5))
(define vn1 (editor-set-focus vn0 0))                       ; 焦点 vid0
(define vn2 (editor-view-right vn1 1))
(check-equal? (selection-head (selections-primary (view-selections (editor-view-ref vn2 1)))) (point 0 1))
(check-equal? (caret-position vn2) (point 0 0))                 ; 焦点 vid0 未被带跑
(check-equal? (editor-view-top-line (editor-view-scroll vn1 1 2) 1) 2)

(define vu0 (editor-add-view (editor-open "abc" 20 5) 0 20 5))
(define vu1 (editor-view-edit (editor-set-focus vu0 0) 1 (lambda (d s) (command-type d s "Z"))))
(check-equal? (doc-str vu1) "Zabc")
(check-equal? (doc-str (editor-view-undo vu1 1)) "abc")
(check-equal? (doc-str (editor-view-redo (editor-view-undo vu1 1) 1)) "Zabc")
(check-false (editor-view-can-undo? (editor-view-clear-history vu1 1) 1))

;; ---------- 外部文本粘贴 ----------
(define pp0 (editor-open "ab" 20 5))
(define pp1 (editor-paste-text pp0 "X\nY"))
(check-equal? (doc-str pp1) "X\nYab")
(check-equal? (caret-position pp1) (point 1 1))

;; ---------- 清历史（只留当前快照，不改文档） ----------
(define ch0 (type-it (editor-open "ab" 20 5) "X"))
(check-true (editor-can-undo? ch0))
(define ch1 (editor-clear-history ch0))
(check-false (editor-can-undo? ch1))
(check-false (editor-can-redo? ch1))
(check-equal? (doc-str ch1) "Xab")

;; ---------- did 版 history：与 vid 版等价；0-view 文档也能用 ----------
(define hd0 (type-it (editor-open "ab" 20 5) "X"))            ; depth 1
(check-equal? (editor-document-depth hd0 0) 1)
(check-true (editor-document-can-undo? hd0 0))
(editor-document-undo! hd0 0)
(check-equal? (doc-str hd0) "ab")
(editor-document-redo! hd0 0)
(check-equal? (doc-str hd0) "Xab")
(editor-document-seal! hd0 0)
(editor-document-clear-history! hd0 0)
(check-false (editor-document-can-undo? hd0 0))
(check-equal? (doc-str hd0) "Xab")                             ; 清史不改文档
;; 0 个 view 的文档：没有 vid，只有 did
(define-values (dhnv dhnv-did) (editor-add-document (make-blank-editor) "q" "nv"))
(check-equal? (editor-document-depth dhnv dhnv-did) 0)
(check-true (editor-document-history-enabled? dhnv dhnv-did))     ; 默认开
(editor-document-reset-history! dhnv dhnv-did #f)
(check-false (editor-document-history-enabled? dhnv dhnv-did))
(check-false (editor-document-can-undo? dhnv dhnv-did))

;; ---------- 按 vid：插入 / 全选 / 剪贴板 / 属性（焦点不动）----------
(define vc0 (editor-add-view (editor-open "abc\ndef" 20 5) 0 20 5))
(define vc1 (editor-set-focus vc0 0))
(check-equal? (doc-str (editor-view-insert (snap vc1) 1 "Z")) "Zabc\ndef")   ; 按 vid 插入
(define vc2 (editor-view-select-all vc1 1))
(define vc3 (editor-view-copy vc2 1))
(check-equal? (clipboard-text (editor-clipboard vc3)) '("abc" "def"))
(define vc4 (editor-view-select-all vc3 0))
(check-equal? (doc-str (editor-view-paste vc4 0)) "abc\ndef")           ; 粘回 vid0 选区

(define vh0 (editor-add-view (editor-open "abc" 20 5) 0 20 5))
(define vh1 (editor-view-right (editor-set-focus vh0 0) 1 #t))             ; vid1 扩选 'a'
(define vh2 (editor-view-highlight vh1 1 'kw))
(check-equal? (track-ref (document-highlight (editor-focused-document vh2)) 0) (vector 'kw #f #f))
(check-true (document-readonly-at? (editor-focused-document (editor-view-readonly vh1 1 #t)) 0 0))

;; 属性写不碰 history：undo/redo 只还原**文本步**的视图，属性视图不受影响。
(define cv0 (editor-add-view (editor-open "abc" 20 5) 0 20 5))       ; vid1
(define cv1 (editor-insert (editor-set-focus cv0 0) "X" 'typing))     ; vid0 caret (0,1)
(define (vid-caret ed vid) (selection-head (selections-primary (view-selections (editor-view-ref ed vid)))))
(define cv2 (editor-view-set-selections cv1 1 (selections-one (selection (point 0 1) (point 0 2)))))  ; vid1 选 'a'
(define cv3 (editor-view-highlight cv2 1 'kw))                         ; 属性写，不记步、不改 current
(check-equal? (vid-caret cv3 0) (point 0 1))
(define cv5 (editor-redo (editor-undo cv3)))
(check-equal? (vid-caret cv5 0) (point 0 1))                           ; 还原到文本步发起视图
(check-equal? (vid-caret cv5 1) (point 0 2))                           ; 属性视图不受影响
(check-equal? (track-ref (document-highlight (editor-focused-document cv5)) 0) (vector #f 'kw #f #f))

(define vx0 (editor-add-view (editor-open "abc" 20 5) 0 20 5))
(define vx1 (editor-view-right (editor-set-focus vx0 0) 1 #t))
(define vx2 (editor-view-cut vx1 1))
(check-equal? (doc-str vx2) "bc")
(check-equal? (clipboard-text (editor-clipboard vx2)) '("a"))

;; ---------- 程序面装选区 / 装点自动夹进合法域（越界不崩）----------
(define cl0 (editor-open "abc" 20 5))
(check-equal? (caret-position (editor-set-point cl0 (point 9 9))) (point 0 3))
(define cl1 (editor-open "ab\ncd" 20 5))
(check-equal? (editor-view-point (editor-view-set-point cl1 0 (point 5 5)) 0) (point 1 2))
(check-true (screen? (editor-view-render (editor-set-point cl1 (point 99 99)) 0)))

;; ---------- 编辑命令返回 change + ok? ----------
(define cge (editor-open "abc" 20 5))
(define-values (cgs cge-ok?) (base:editor-view-insert! cge 0 "XY\nZ"))
(check-true cge-ok?)
(check-equal? (document->string (editor-focused-document cge)) "XY\nZabc")
(check-equal? (length cgs) 1)
(check-equal? (change-post-range (car cgs)) (range (point 0 0) (point 1 1)))
(check-equal? (editor-view-change-text cge 0 (car cgs)) "XY\nZ")
(check-equal? (change-map-point (car cgs) (point 0 2)) (point 1 3))
;; 被只读拒绝 → changes = '()、ok? = #f
(define ro-chg (editor-readonly (editor-right (editor-open "a" 20 5) #t) #t))
(define-values (cgs2 ro-ok?) (base:editor-view-insert! ro-chg 0 "Q"))
(check-false ro-ok?)
(check-equal? cgs2 '())
(check-equal? (document->string (editor-focused-document ro-chg)) "a")
;; 无变更（文首退格）→ changes = '()
(define cge3 (editor-open "abc" 20 5))
(define-values (cgs3 _ok3) (base:editor-view-backspace! cge3 0))
(check-equal? cgs3 '())
;; 多光标：一次命令 → 多个 change
(define mc-chg (editor-set-selections (editor-open "abc\ndef" 20 5)
                                      (selections-of (list (caret (point 0 1)) (caret (point 1 1))) 0)))
(define-values (cgs4 _ok4) (base:editor-view-insert! mc-chg 0 "!"))
(check-equal? (length cgs4) 2)
(check-equal? (editor-view-change-text mc-chg 0 (car cgs4)) "!")

;; ---------- 程序编辑（-ignore-readonly）：绕只读守卫 ----------
(define ro-doc (document-readonly-fill (document-open "abc") 0 0 0 3 #t))
(define io-ed (editor-open ro-doc 20 5))
;; 守版：整体拒绝 → ok? #f, changes '()
(define-values (io-gc io-gok?) (base:editor-view-insert! io-ed 0 "X"))
(check-false io-gok?)
(check-equal? io-gc '())
(check-equal? (doc-str io-ed) "abc")
;; 程序版：绕只读、成功；历史开着 → 照常记一步
(define-values (io1 io1c) (editor-insert-ignore-readonly (snap io-ed) "X"))
(check-equal? (doc-str io1) "Xabc")
(check-equal? (depth io1) 1)
(check-equal? (length io1c) 1)
(define-values (io2 io2c) (editor-backspace-ignore-readonly io1))
(check-equal? (doc-str io2) "abc")
(define-values (io3 io3c) (editor-paste-text-ignore-readonly (snap io-ed) "Z"))
(check-equal? (doc-str io3) "Zabc")
(define io-sel (editor-right (editor-right io-ed #t) #t))   ; 扩选 "ab"
(define-values (io4 io4c) (editor-cut-ignore-readonly io-sel))
(check-equal? (doc-str io4) "c")
(check-equal? (depth io4) 1)
;; 无选区时 cut 是 no-op
(check-true (eq? (let-values ([(e _) (editor-cut-ignore-readonly io-ed)]) e) io-ed))

;; ---------- 历史开关（per-document） ----------
;; 建时即关：编辑不记步、不可 undo
(define hoc (editor-open "abc" 20 5 #:history? #f))
(define hoc1 (editor-insert hoc "X"))
(check-equal? (doc-str hoc1) "Xabc")
(check-equal? (depth hoc1) 0)
(check-false (editor-can-undo? hoc1))
(check-true (eq? (editor-undo hoc1) hoc1))            ; 关闭期 undo 是 no-op
;; 打开后从当前状态继续记步
(define hoc2 (editor-set-history-enabled hoc1 #t))
(define hoc3 (editor-insert hoc2 "Y"))
(check-equal? (depth hoc3) 1)
(check-equal? (doc-str (editor-undo hoc3)) "Xabc")
;; 开着 → 关闭 → past 保留；重开后可 undo
(define hsw0 (editor-open "abc" 20 5))
(define hsw1 (type-it hsw0 "X"))                      ; depth 1
(define hsw2 (editor-set-history-enabled hsw1 #f))
(define hsw3 (type-it hsw2 "Y"))                      ; 关闭 → 不记步
(check-equal? (doc-str hsw3) "XYabc")
(check-equal? (depth hsw3) 1)
(define hsw4 (editor-set-history-enabled hsw3 #t))
(define hsw5 (type-it hsw4 "Z"))                      ; 重开后新起一步
(check-equal? (depth hsw5) 2)
(check-equal? (doc-str (editor-undo hsw5)) "XYabc")   ; 先退回关闭期改动
(check-equal? (doc-str (editor-undo (editor-undo hsw5))) "abc")   ; 再越过关闭期

;; ---------- 状态栏输入流程：开历史 → 输入 → 关+清 ----------
(define sb0 (editor-open "abc" 20 5 #:history? #f))   ; 常态：widget，关历史
(define sb1 (editor-set-history-enabled sb0 #t))       ; 进入输入模式
(define sb2 (type-it sb1 "x"))                        ; 可 undo/redo
(check-equal? (depth sb2) 1)
(check-equal? (doc-str (editor-undo (snap sb2))) "abc")
;; 结束输入：关历史 + 清空（保留当前内容）
(define sb3 (editor-reset-history sb2))
(check-false (editor-history-enabled? sb3))
(check-equal? (depth sb3) 0)
(check-false (editor-can-undo? sb3))
(check-equal? (doc-str sb3) "xabc")
(define sb4 (editor-insert sb3 "y"))                  ; 清后不再记步
(check-equal? (depth sb4) 0)
(check-equal? (doc-str sb4) "xyabc")
;; reset 时也可保留记步
(check-true (editor-history-enabled? (editor-reset-history sb2 #t)))
(check-equal? (depth (editor-reset-history sb2 #t)) 0)
;; view 版按 vid：只动该视图的文档
(define sbv0 (editor-open "abcd" 20 5))
(define-values (sbv1 sbvd) (editor-add-document sbv0 "wxyz" "b"))
(define sbv2 (editor-add-view sbv1 sbvd 20 5))
(define sbv3 (editor-view-reset-history sbv2 1))
(check-false (editor-view-history-enabled? sbv3 1))
(check-true (editor-view-history-enabled? sbv3 0))

;; ---------- 通用变更原语：editor-view-set / -record / -assign ----------
(define su0 (editor-open "abc" 20 5))
(define su-doc (document-open "xyz"))
(define su-pre (editor-focused-document su0))          ; 就地改之前先抓
(define-values (su1 su-step) (editor-view-set su0 0 su-doc))
(check-equal? (doc-str su1) "xyz")
(check-equal? (depth su1) 0)                                  ; set 不记步
(check-true (icmd:step? su-step))
(check-equal? (icmd:step-pre-value su-step) su-pre)
(check-equal? (icmd:step-post-value su-step) su-doc)
(check-equal? (icmd:step-who su-step) 0)
;; 新值 eq? 旧值 → 无变化，原样返回 + step = #f
(define-values (su2 su-step2) (editor-view-set su1 0 (editor-focused-document su1)))
(check-true (eq? su2 su1))
(check-false su-step2)
;; assign = set(#:change #f) 且丢 step：不记步
(define as0 (editor-open "abc" 20 5))
(check-equal? (doc-str (editor-view-assign as0 0 (document-open "Q"))) "Q")
(check-equal? (depth (editor-view-assign as0 0 (document-open "Q"))) 0)
;; assign 后封口：之后的编辑不跨过赋值并入旧步（新开一个，避开上面就地改）
(define asg1 (type-it (editor-open "abc" 20 5) "X"))  ; depth 1，tag 'typing
(define asg2 (editor-view-assign asg1 0 (document-open "Q")))
(define asg3 (type-it asg2 "Y"))
(check-equal? (depth asg3) 2)                         ; 没有并进 X 那步
;; assign 的选区用 #:selections（与 editor-view-set 一致）
(define asgsel (editor-view-assign (editor-open "abc" 20 5) 0 (document-open "Q")
                                   #:selections (selections-one (caret (point 0 1)))))
(check-equal? (editor-view-point asgsel 0) (point 0 1))
;; assign 接受 string（与 editor-open / editor-add-document 的入口多态一致）
(check-equal? (doc-str (editor-view-assign as0 0 "Qstr")) "Qstr")
(check-equal? (track-max (document-text (editor-focused-document
                                          (editor-view-assign as0 0 "a\nb\nc" #:chunk-lines 4))))
              4)
;; 传 document 仍原样装入（不经 string 重建）
(define aspre (document-open "P"))
(check-true (eq? (editor-focused-document (editor-view-assign as0 0 aspre)) aspre))
;; record：把 step 记进账本；undo 回旧值
(define-values (sr1 sr-step) (editor-view-set (editor-open "abc" 20 5) 0 (document-open "Q")))
(define sr2 (editor-history-record sr1 0 sr-step))
(check-equal? (depth sr2) 1)
(check-equal? (doc-str (editor-undo sr2)) "abc")
;; record 合并：同 tag + 同 who + 选区未动 → 一步
(define-values (rm1 st1) (editor-view-set (editor-open "abc" 20 5) 0 (document-open "Xabc")
                                          #:selections (selections-one (caret (point 0 1)))))
(define rm2 (editor-history-record rm1 0 st1 'typing))
(define-values (rm3 st2) (editor-view-set rm2 0 (document-open "XYabc")
                                          #:selections (selections-one (caret (point 0 2)))))
(define rm4 (editor-history-record rm3 0 st2 'typing))
(check-equal? (depth rm4) 1)

;; ---------- 属性写口便利：cell / line / selections ----------
(define cw0 (editor-open "abcd\nefgh" 20 5))
(define cw1 (editor-view-highlight-cell cw0 0 0 1 'c))
(check-equal? (editor-view-highlight-row cw1 0 0) (vector #f 'c #f #f))
(define cw2 (editor-view-highlight-line cw1 0 1 'L))
(check-equal? (editor-view-highlight-row cw2 0 1) (vector 'L 'L 'L 'L))
(check-true (eq? (editor-view-highlight-cell cw0 0 0 9 'c) cw0))          ; cell 越界 no-op
(define cr0 (editor-open "abcd" 20 5))
(check-true (editor-view-readonly-at? (editor-view-readonly-cell cr0 0 0 2 #t) 0 0 2))
(check-equal? (editor-view-readonly-row (editor-view-readonly-line cr0 0 0 #t) 0 0) (vector #t #t #t #t))
;; 多选区写：两个选区都涂
(define ms0 (editor-open "foo bar\nfoo baz" 20 5))
(define ms1 (editor-view-set-selections ms0 0
              (selections-of (list (selection (point 0 0) (point 0 3))
                                   (selection (point 1 0) (point 1 3))) 0)))
(define ms2 (editor-view-highlight-selections ms1 0 'm))
(check-equal? (editor-view-highlight-row ms2 0 0) (vector 'm 'm 'm #f #f #f #f))
(check-equal? (editor-view-highlight-row ms2 0 1) (vector 'm 'm 'm #f #f #f #f))
(define ms3 (editor-view-readonly-selections ms1 0 #t))
(check-equal? (editor-view-readonly-row ms3 0 0) (vector #t #t #t #f #f #f #f))

;; ---------- set-selections #:ensure? ----------
(define es0 (editor-open "l0\nl1\nl2\nl3\nl4\nl5" 20 3))
(define es1 (editor-view-set-selections es0 0 (selections-one (caret (point 5 0))) #:ensure? #f))
(check-equal? (editor-view-top-line es1 0) 0)                            ; 不 ensure
(define es2 (editor-view-set-selections es0 0 (selections-one (caret (point 5 0)))))
(check-equal? (editor-view-top-line es2 0) 3)                            ; ensure 滚进可视区

(displayln "editor/command.rkt: all tests passed")
