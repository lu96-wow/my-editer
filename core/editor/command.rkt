#lang racket

(require "state.rkt" "attributes.rkt" "view.rkt" "sync.rkt"
         "../text/document.rkt" "history.rkt" "../text/command.rkt"
         "../text/base/point.rkt" "../text/base/selection.rkt" "../text/base/track.rkt"
         "../text/base/line.rkt" "../text/base/range.rkt"
         "../view/base/viewport.rkt")

;;; editor/command.rkt —— 命令式操作（就地改 box，**不返回 editor**）
;;;
;;; 命名：全部按 vid（`editor-view-*!`）；**无焦点糖**（焦点由宿主自理）。
;;;
;;; 返回约定：
;;;     编辑命令（insert/backspace/delete/paste/cut/edit）  → (values changes ok?)
;;;                                                          changes 空 = 没改动；ok? #f = 被只读挡
;;;     undo / redo                                        → ok?
;;;     异步文本 CAS                                        → applied?
;;;     其余（导航 / 视口 / 选区 / 作者态 / 清栈 / 改名 …）  → void
;;;
;;; 结构操作（增/删文档、视图）在 state.rkt，**返回新 editor**。
;;;
;;; 内容写原语 editor-view-install!：换当前文档 + 传播视图 + 同步视口；→ step（#f = 无变化）。
;;; 作者态（高亮 / readonly）不在这里：属性写是文档级、出带，见 attributes.rkt。

(provide
 ;; ---------- 内部件（只 core 内部 / 测试用；入口 editor.rkt 会 except-out） ----------
 (struct-out step)
 editor-view-install! editor-document-history-record!

 ;; ---------- 内容写 ----------
 ;; 值级程序替换（封口、不记步）；op 级记步编辑见 editor-view-edit!。
 editor-view-assign!

 ;; ---------- 编辑 ----------
 editor-view-edit!
 editor-view-insert! editor-view-insert-ignore-readonly!
 editor-view-backspace! editor-view-backspace-ignore-readonly!
 editor-view-delete! editor-view-delete-ignore-readonly!

 ;; ---------- 异步文本写（CAS） ----------
 editor-view-apply-text-if-version!

 ;; ---------- 剪贴板 ----------
 editor-view-copy!
 editor-view-cut! editor-view-cut-ignore-readonly!
 editor-view-paste! editor-view-paste-ignore-readonly!
 editor-view-paste-text! editor-view-paste-text-ignore-readonly!

 ;; ---------- 导航 ----------
 editor-view-left! editor-view-right! editor-view-up! editor-view-down!
 editor-view-home! editor-view-end!

 ;; ---------- 选区 / 定位 ----------
 editor-view-set-selections! editor-view-select-all! editor-view-set-point! editor-view-goto!

 ;; ---------- 滚动 / 视口 ----------
 editor-view-scroll! editor-view-set-top-line! editor-view-set-left-column!
 editor-view-set-mode! editor-view-toggle-line-numbers! editor-view-set-size!

 ;; ---------- 属性（只在「作用选区」时需要 vid；坐标/整轨写在 attributes.rkt） ----------
 editor-view-highlight! editor-view-highlight-selections!
 editor-view-readonly! editor-view-readonly-selections!

 ;; ---------- 历史 ----------
 editor-view-undo! editor-view-redo!
 editor-document-undo! editor-document-redo!
 editor-view-clear-history! editor-view-reset-history! editor-view-seal!
 editor-document-clear-history! editor-document-reset-history! editor-document-seal!
 editor-view-set-history-enabled!)

;;; ---------- 通用内容原语（就地；内部件，不导出） ----------

(struct step (pre-value pre-sels post-value post-sels who pre-tip) #:transparent)

;; 换当前文档 + 传播视图 + 同步视口。→ step（#f = 无实际变化）。
;; value : string | document（与 editor-open / editor-add-document 同构）：
;; string 现开一篇纯文本，document 则原样装入（含属性轨）。
(define (editor-view-install! ed vid value
                          #:selections [sels #f]
                          #:change [changes #f]
                          #:ensure? [ensure? #t]
                          #:chunk-lines [chunk-lines default-chunk-lines])
  (define value* (->document value chunk-lines))
  (define v (editor-view-ref ed vid))
  (define did (view-did v))
  (define e (editor-document-entry ed did))
  (define old (document-entry-document e))
  (cond
    [(eq? value* old) #f]
    [else
     (define t (document-text value*))
     (define n (track-length t))
     (define sels* (selections-clamp (or sels (view-selections v)) n (curry track-line-length t)))
     (define pre-sels (view-selections v))                            ; 就地改之前先抓
     (define pre-tip (history-current (document-entry-history e)))
     (view-set-selections! v sels*)
     (when ensure? (view-ensure! value* v))
     (document-entry-set-history! e (history-set-current (document-entry-history e) value* sels* vid))
     (if (and changes (pair? changes))
         (editor-views-rebase! ed did vid changes)
         (editor-views-clamp! ed did))
     (editor-sync-viewports! ed vid)
     (step old pre-sels value* sels* vid pre-tip)]))

;; 把一次 step 记进账本（哑栈原语；是否并步由 merge-tag 判定）。
(define (editor-document-history-record! ed did step [merge-tag #f])
  (cond
    [(not step) (void)]
    [else
     (define e (editor-document-entry ed did))
     (define h (document-entry-history e))
     (define pre-tip (step-pre-tip step))
     (define pre-sels (step-pre-sels step))
     (define post-value (step-post-value step))
     (define post-sels (step-post-sels step))
     (define who (step-who step))
     (define merge? (and merge-tag
                         (equal? merge-tag (snapshot-merge-tag pre-tip))
                         (equal? who (snapshot-who pre-tip))
                         (equal? pre-sels (snapshot-selections pre-tip))))
     (document-entry-set-history!
      e (cond [merge? (history-merge h post-value post-sels)]
              [else (history-record h (step-pre-value step) pre-sels
                                    post-value post-sels who merge-tag)]))
     (void)]))

;; 程序赋值：不记步、默认不 ensure；整篇替换后封口。
;; value : string | document。传 string 时可给 #:chunk-lines。
(define (editor-view-assign! ed vid value #:selections [sels #f] #:ensure? [ensure? #f]
                             #:chunk-lines [chunk-lines default-chunk-lines])
  (define did (view-did (editor-view-ref ed vid)))
  (define step (editor-view-install! ed vid value #:selections sels #:change #f #:ensure? ensure?
                                     #:chunk-lines chunk-lines))
  (when step
    (document-entry-set-history! (editor-document-entry ed did)
                                 (history-seal (editor-document-history ed did))))
  (void))

;;; ---------- 编辑命令 ----------

(define (editor-view-edit! ed vid op [merge-tag #f] [ensure? #t])
  (define v (editor-view-ref ed vid))
  (define did (view-did v))
  (define e (editor-document-entry ed did))
  (define-values (doc* sels* changes ok?) (op (document-entry-document e) (view-selections v)))
  (cond
    [(not ok?) (values '() #f)]                                  ; 被只读挡
    [(null? changes) (values '() #t)]                            ; 无变更
    [else
     (define step (editor-view-install! ed vid doc* #:selections sels* #:change changes #:ensure? ensure?))
     (cond
       [(not step) (values '() #t)]
       [else (editor-document-history-record! ed did step merge-tag) (values changes #t)])]))

(define (editor-view-insert! ed vid text [merge-tag #f])
  (editor-view-edit! ed vid (lambda (d s) (command-type d s text)) merge-tag))
(define (editor-view-backspace! ed vid [merge-tag #f])
  (editor-view-edit! ed vid command-backspace merge-tag))
(define (editor-view-delete! ed vid [merge-tag #f])
  (editor-view-edit! ed vid command-delete merge-tag))

(define (editor-view-insert-ignore-readonly! ed vid text [merge-tag #f])
  (editor-view-edit! ed vid (lambda (d s) (command-type-ignore-readonly d s text)) merge-tag))
(define (editor-view-backspace-ignore-readonly! ed vid [merge-tag #f])
  (editor-view-edit! ed vid command-backspace-ignore-readonly merge-tag))
(define (editor-view-delete-ignore-readonly! ed vid [merge-tag #f])
  (editor-view-edit! ed vid command-delete-ignore-readonly merge-tag))

;;; ---------- 异步文本写：版本校验（CAS） ----------

;; base-text = 请求时抓的文本轨；命中才装（记一步），否则丢弃。→ applied?
;; core 只做版本校验；**同 did 的串行 / 锁由调用方保证**。
(define (editor-view-apply-text-if-version! ed vid base-text new-doc [merge-tag #f])
  (cond
    [(not (eq? (document-text (editor-view-document ed vid)) base-text)) #f]
    [else
     (define did (view-did (editor-view-ref ed vid)))
     (define step (editor-view-install! ed vid new-doc))
     (when step (editor-document-history-record! ed did step merge-tag))
     #t]))

;;; ---------- 剪贴板 ----------

(define (editor-view-copy! ed vid)
  (define v (editor-view-ref ed vid))
  (define doc (document-entry-document (editor-document-entry ed (view-did v))))
  (define s (selections-primary (view-selections v)))
  (define-values (a b) (selection-range s))
  (editor-set-clipboard! ed (document-copy doc (point-line a) (point-column a) (point-line b) (point-column b)))
  (void))

(define (editor-view-paste! ed vid [merge-tag #f])
  (define cp (editor-clipboard ed))
  (cond [(not cp) (values '() #t)]
        [else (editor-view-edit! ed vid (lambda (d s) (command-paste d s cp)) merge-tag)]))

(define (editor-view-paste-text! ed vid text [merge-tag #f])
  (editor-view-edit! ed vid (lambda (d s) (command-paste d s (clipboard-of-text text))) merge-tag))

(define (editor-view-cut! ed vid [merge-tag #f])
  (define v (editor-view-ref ed vid))
  (cond
    [(for/or ([s (in-list (selections-items (view-selections v)))]) (not (selection-empty? s)))
     (editor-view-copy! ed vid)
     (editor-view-edit! ed vid (lambda (d ss) (command-delete d ss)) merge-tag)]
    [else (values '() #t)]))

(define (editor-view-paste-ignore-readonly! ed vid [merge-tag #f])
  (define cp (editor-clipboard ed))
  (cond [(not cp) (values '() #t)]
        [else (editor-view-edit! ed vid (lambda (d s) (command-paste-ignore-readonly d s cp)) merge-tag)]))

(define (editor-view-paste-text-ignore-readonly! ed vid text [merge-tag #f])
  (editor-view-edit! ed vid (lambda (d s) (command-paste-ignore-readonly d s (clipboard-of-text text))) merge-tag))

(define (editor-view-cut-ignore-readonly! ed vid [merge-tag #f])
  (define v (editor-view-ref ed vid))
  (cond
    [(for/or ([s (in-list (selections-items (view-selections v)))]) (not (selection-empty? s)))
     (editor-view-copy! ed vid)
     (editor-view-edit! ed vid (lambda (d ss) (command-delete-ignore-readonly d ss)) merge-tag)]
    [else (values '() #t)]))

;;; ---------- 导航 ----------

(define (editor-view-nav! ed vid f extend?)
  (define v (editor-view-ref ed vid))
  (define did (view-did v))
  (define doc (document-entry-document (editor-document-entry ed did)))
  (define sels* ((if extend? selections-extend selections-go) (view-selections v) f))
  (view-set-selections! v sels*)
  (view-ensure! doc v)
  (editor-sync-viewports! ed vid)
  (void))

(define (editor-view-char-nav! ed vid which extend?)
  (define t (document-text (editor-view-document ed vid)))
  (define f (case which
              [(left) (lambda (p) (point-left t p))]
              [(right) (lambda (p) (point-right t p))]
              [(home) (lambda (p) (point-home t p))]
              [(end) (lambda (p) (point-end t p))]))
  (editor-view-nav! ed vid f extend?))

(define (editor-view-left! ed vid [extend? #f]) (editor-view-char-nav! ed vid 'left extend?))
(define (editor-view-right! ed vid [extend? #f]) (editor-view-char-nav! ed vid 'right extend?))
(define (editor-view-home! ed vid [extend? #f]) (editor-view-char-nav! ed vid 'home extend?))
(define (editor-view-end! ed vid [extend? #f]) (editor-view-char-nav! ed vid 'end extend?))

(define (editor-view-visual-nav! ed vid up? extend?)
  (define t (document-text (editor-view-document ed vid)))
  (define vp (view-viewport (editor-view-ref ed vid)))
  (editor-view-nav! ed vid (lambda (p) ((if up? point-up point-down) t vp p)) extend?))

(define (editor-view-up! ed vid [extend? #f]) (editor-view-visual-nav! ed vid #t extend?))
(define (editor-view-down! ed vid [extend? #f]) (editor-view-visual-nav! ed vid #f extend?))

;;; ---------- 选区 ----------

(define (editor-view-set-selections! ed vid sels #:ensure? [ensure? #t])
  (define v (editor-view-ref ed vid))
  (define did (view-did v))
  (define doc (document-entry-document (editor-document-entry ed did)))
  (define t (document-text doc))
  (define n (track-length t))
  (view-set-selections! v (selections-clamp sels n (curry track-line-length t)))
  (when ensure? (view-ensure! doc v))
  (editor-sync-viewports! ed vid)
  (void))

(define (editor-view-select-all! ed vid)
  (define t (document-text (editor-view-document ed vid)))
  (define last (sub1 (track-length t)))
  (editor-view-set-selections! ed vid
    (selections-one (selection (point 0 0) (point last (track-line-length t last))))))

(define (editor-view-set-point! ed vid p)
  (editor-view-set-selections! ed vid (selections-one (caret p))))

(define (editor-view-goto! ed vid p) (editor-view-set-point! ed vid p))

;;; ---------- 视口 ----------

(define (editor-view-scroll! ed vid delta)
  (define v (editor-view-ref ed vid))
  (define t (document-text (editor-view-document ed vid)))
  (view-set-viewport! v (viewport-scroll t (view-viewport v) delta))
  (editor-sync-viewports! ed vid)
  (void))

;; 改视口字段的公共壳：按旧 mode 取锚点，改完落回同锚，再同步跟随者。
(define (editor-view-viewport-update! ed vid f)
  (define v (editor-view-ref ed vid))
  (define t (document-text (editor-view-document ed vid)))
  (define-values (line dc) (viewport-anchor t (view-viewport v)))
  (view-set-viewport! v (viewport-set-anchor t (f (view-viewport v)) line dc))
  (editor-sync-viewports! ed vid)
  (void))

(define (editor-view-set-mode! ed vid mode)
  (editor-view-viewport-update! ed vid (lambda (vp) (viewport-set-mode vp mode))))

(define (editor-view-toggle-line-numbers! ed vid)
  (editor-view-viewport-update!
   ed vid (lambda (vp) (viewport-set-line-numbers vp (not (viewport-line-numbers? vp))))))

(define (editor-view-set-size! ed vid width height)
  (editor-view-viewport-update! ed vid (lambda (vp) (viewport-set-size vp width height))))

(define (editor-view-set-top-line! ed vid n)
  (define v (editor-view-ref ed vid))
  (view-set-viewport! v (viewport-set-top-line (view-viewport v) n))
  (editor-sync-viewports! ed vid)
  (void))

(define (editor-view-set-left-column! ed vid n)
  (define v (editor-view-ref ed vid))
  (define t (document-text (editor-view-document ed vid)))
  (view-set-viewport! v (viewport-set-left-column t (view-viewport v) n))
  (editor-sync-viewports! ed vid)
  (void))

;;; ---------- 属性命令（视图级：只有「作用选区」需要 vid） ----------
;;; 属性写一律是**文档级**（attributes.rkt 的 editor-document-*），不碰 history。
;;; 这里只留「区间从当前选区来」的四个命令；vid 仅用于读选区，算完就转 did 版。

(define (vid->did ed vid) (view-did (editor-view-ref ed vid)))

;; 主选区 → range（选区是视图态，所以这个入口必须在 view 层）。
(define (primary-range ed vid)
  (define-values (a b) (selection-range (selections-primary (view-selections (editor-view-ref ed vid)))))
  (range-of a b))

(define (editor-view-highlight! ed vid face)
  (editor-document-highlight-range! ed (vid->did ed vid) (primary-range ed vid) face))
(define (editor-view-readonly! ed vid flag)
  (editor-document-readonly-range! ed (vid->did ed vid) (primary-range ed vid) flag))

(define (editor-view-highlight-selections! ed vid face)
  (define did (vid->did ed vid))
  (for ([sel (in-list (selections-items (view-selections (editor-view-ref ed vid))))])
    (define-values (a b) (selection-range sel))
    (editor-document-highlight-range! ed did (range-of a b) face)))
(define (editor-view-readonly-selections! ed vid flag)
  (define did (vid->did ed vid))
  (for ([sel (in-list (selections-items (view-selections (editor-view-ref ed vid))))])
    (define-values (a b) (selection-range sel))
    (editor-document-readonly-range! ed did (range-of a b) flag)))

;; 坐标 / 区间 / 整轨版一律走 editor-document-*（did）；
;; 「选区版」是唯一需要 vid 的属性命令（选区是视图态）。

;;; ---------- 撤销 / 重做 ----------
;;; history 是**文档级**状态，所以这些操作一律按 did；vid 版只是「就地取 did」的糖。

;; undo/redo 共用：step : history -> (values history ok?)。→ ok?
(define (editor-document-time-travel! ed did step)
  (define-values (h* ok?) (step (editor-document-history ed did)))
  (cond
    [(not ok?) #f]
    [else
     (define-values (_doc sels* who) (history-state h*))
     (document-entry-set-history! (editor-document-entry ed did) h*)
     (editor-views-clamp! ed did)
     ;; 选区还原到**发起那次编辑的视图**（快照里的 who），与调用者传的 vid 无关。
     (when (and who (for/or ([x (in-list (editor-views ed))] #:when (= (view-id x) who)) #t))
       (view-set-selections! (editor-view-ref ed who) sels*))
     #t]))

(define (editor-document-undo! ed did) (editor-document-time-travel! ed did history-undo))
(define (editor-document-redo! ed did) (editor-document-time-travel! ed did history-redo))
(define (editor-view-undo! ed vid)
  (editor-document-undo! ed (view-did (editor-view-ref ed vid))))
(define (editor-view-redo! ed vid)
  (editor-document-redo! ed (view-did (editor-view-ref ed vid))))

(define (editor-document-clear-history! ed did)
  (document-entry-set-history! (editor-document-entry ed did)
                               (history-clear (editor-document-history ed did)))
  (void))
(define (editor-document-reset-history! ed did [enabled? #f])
  (document-entry-set-history! (editor-document-entry ed did)
                               (history-set-enabled (history-clear (editor-document-history ed did)) enabled?))
  (void))
(define (editor-document-seal! ed did)
  (document-entry-set-history! (editor-document-entry ed did)
                               (history-seal (editor-document-history ed did)))
  (void))

(define (editor-view-clear-history! ed vid)
  (editor-document-clear-history! ed (view-did (editor-view-ref ed vid))))
(define (editor-view-reset-history! ed vid [enabled? #f])
  (editor-document-reset-history! ed (view-did (editor-view-ref ed vid)) enabled?))
(define (editor-view-seal! ed vid)
  (editor-document-seal! ed (view-did (editor-view-ref ed vid))))

(define (editor-view-set-history-enabled! ed vid flag)
  (editor-document-set-history-enabled! ed (view-did (editor-view-ref ed vid)) flag))
