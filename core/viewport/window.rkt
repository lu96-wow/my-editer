#lang racket

(require "../atom/point.rkt" "../atom/selection.rkt" "../atom/selection-set.rkt"
         "../doc/buffer.rkt" "../doc/document.rkt"
         "../atom/width.rkt" racket/list rackunit)

;;; viewport/window.rkt —— 视口：buffer 引用 + 本窗口的选区集合 + 滚动位置 + 尺寸
;;;
;;; buffer 是文档（无光标）；window 是「怎么看它」，持有自己的**选区集合**（至少一个）。
;;; 一个 buffer 可被多个 window 绑定，各有独立选区。
;;;
;;;   selection-set         : selection-set   本窗口的选区（名字 + 区间集 + leader，已规范化）
;;;   空选区 (anchor=head) 就是普通光标；单个 window 至少含一个空选区。
;;;
;;; 本层是**纯视图**：导航、滚动、尺寸。**编辑不在这里**。
;;; 坐标：point 的 col 是**字符索引**；top-line/top-seg/left-col 是**显示列/行**。

(provide
 (struct-out window)
 window-open
 window-buffer
 window-set-document
 window-set-line-numbers
 check-mode
 snap-left-col
 point-left
 point-right
 point-home
 point-end
 window-point
 window-selections
 window-primary
 window-primary-index
 window-selection-set-name
 window-set-selection-set
 window-clear-selection-set
 window-map-selections
 window-map-primary
 window-set-document
 window-set-point
 window-set-selections
 window-add-selections
 window-remove-selections
 window-add-selection
 window-remove-selection
 window-set-primary
 window-set-primary-index
 window-selection-member?
 window-map-points
 window-clamp-selections
 window-set-mode
 window-set-top-line
 window-set-left-col
 window-set-top-seg
 window-set-size
 window-vscroll
 window-hscroll
 window-left
 window-right
 window-home
 window-end)

(struct window
  (document      ; document（buffer ⊕ attrs）
   selection-set         ; selection-set：名字 + 区间集 + leader
   mode          ; 'clip|'wrap
   top-line      ; nat        clip/wrap：顶部所在 buffer 行
   left-col      ; nat        clip：水平滚动列（wrap 下被布局忽略；值保留，切回 clip 再生效）
   top-seg       ; nat        wrap：顶部行的第几个折行段（clip 下被布局忽略；同上）
   height        ; nat        可见行数
   width         ; nat        可见列数（含行号栏）
   line-numbers?) ; boolean   是否在左侧留行号栏（宽度由 layout 派生，不存）
  #:transparent)

(define (window-open d [height 24] [width 80])
  (unless (and (exact-nonnegative-integer? height) (>= height 1))
    (error 'window-open "height 必须 ≥ 1，得到 ~a" height))
  (unless (and (exact-nonnegative-integer? width) (>= width 1))
    (error 'window-open "width 必须 ≥ 1，得到 ~a" width))
  (window d (selection-set-open #f (list (caret (point 0 0))) 0) 'clip 0 0 0 height width #f))

;; 行号栏开关（视图装饰）。宽度不由本层存：由 layout 按当前视口的行号上界现算。
(define (window-set-line-numbers w on?) (struct-copy window w [line-numbers? (and on? #t)]))

;; 本视图看的**文本**（属性在 window-document 的 attrs 里）。
(define (window-buffer w) (document-buffer (window-document w)))

;;; ---------- 光标 / 选区（都是 selection-set 的派生视图）----------

(define (window-selections w) (selection-set-selections (window-selection-set w)))
(define (window-primary-index w) (selection-set-leader-index (window-selection-set w)))
;; 显式 primary：给选区**值**，不靠位置比较。
(define (window-primary w) (selection-set-leader (window-selection-set w)))
(define (window-point w) (selection-point (window-primary w)))

;; 名字（“命名区间组”）；#f = 匿名。
(define (window-selection-set-name w) (selection-set-name (window-selection-set w)))
;; 安装一个现成的选区集（含名字）。
(define (window-set-selection-set w g) (struct-copy window w [selection-set g]))
;; 清除：收敛为单个选区（leader），名字丢弃。**何时调用由上层决定**。
(define (window-clear-selection-set w) (struct-copy window w [selection-set (selection-set-clear (window-selection-set w))]))

(define (clamp-selection b s)
  (selection (buffer-clamp-point b (selection-anchor s))
             (buffer-clamp-point b (selection-head s))))

;; 把现有选区夹进 buffer 合法域并规范化；leader 追到它合并后的那个。
(define (window-clamp-selections w)
  (define b (window-buffer w))
  (define g (window-selection-set w))
  (define sels (map (lambda (s) (clamp-selection b s)) (selection-set-selections g)))
  (struct-copy window w [selection-set (selection-set-open (selection-set-name g) sels (selection-set-leader-index g))]))

(define (window-set-document w d)
  (window-clamp-selections (struct-copy window w [document d])))

;; 设成单个空选区（程序面「把光标放这」的语义）；名字清空。
(define (window-set-point w p)
  (define q (buffer-clamp-point (window-buffer w) p))
  (struct-copy window w [selection-set (selection-set-open #f (list (caret q)) 0)]))

;; 设一组选区；primary 按输入下标选，规范化后追到合并结果；名字保持。
(define (window-set-selections w sels [primary-index 0])
  (unless (pair? sels) (error 'window-set-selections "至少一个选区"))
  (define b (window-buffer w))
  (define clamped (map (lambda (s) (clamp-selection b s)) sels))
  (struct-copy window w [selection-set (selection-set-open (window-selection-set-name w) clamped primary-index)]))

;; 对每个选区施加 f（selection → selection），再规范化；primary 保持。
(define (window-map-selections w f)
  (window-set-selections w (map f (window-selections w)) (window-primary-index w)))

;; 只对 primary 施加 f（selection → selection）；其余不动，primary 保持。
(define (window-map-primary w f)
  (define i (window-primary-index w))
  (define sels (window-selections w))
  (window-set-selections w (list-set sels i (f (list-ref sels i))) i))

;; 增/删单个选区；set-primary 让集合中等于 s 的选区成为 primary（不在集合中则原样）。
(define (window-add-selection w s #:primary? [primary? #f])
  (window-add-selections w (list s) #:primary? primary?))
(define (window-remove-selection w s)
  (window-remove-selections w (list s)))
(define (window-set-primary w s)
  (struct-copy window w [selection-set (selection-set-set-leader (window-selection-set w) s)]))

;; 直接设 primary 下标；越界夹回合法域（选区集非空）。
(define (window-set-primary-index w i)
  (struct-copy window w [selection-set (selection-set-open (window-selection-set-name w) (window-selections w) i)]))
(define (window-selection-member? w s)
  (and (member s (window-selections w)) #t))

;; 对每个选区的 head 施加 f（point → point），坍缩成空选区；primary 跟随。
;; 导航（方向键）用它：一次动所有光标。
(define (window-map-points w f)
  (define moved (for/list ([s (in-list (window-selections w))])
                  (caret (f (selection-head s)))))
  (struct-copy window w [selection-set (selection-set-open (window-selection-set-name w) moved (window-primary-index w))]))

;; 并集：把 sels 加进现有选区集（规范化）；primary 默认保持，#:primary? #t 则让新加的成为 primary。
;; 空集是恒等（不改变 primary）。
(define (window-add-selections w sels #:primary? [primary? #f])
  (cond
    [(null? sels) w]
    [else
     (struct-copy window w
       [selection-set (selection-set-open (window-selection-set-name w)
                          (append (window-selections w) sels)
                          (if primary? (length (window-selections w)) (window-primary-index w)))])]))

;; 差集：从现有选区集去掉与 drops 相等的项；primary 尽量保持，删空则原样。
(define (window-remove-selections w drops)
  (define old (window-selections w))
  (define leader (window-primary w))
  (define kept (remove* drops old))
  (cond
    [(null? kept) w]
    [else
     (define idx (or (for/first ([s (in-list kept)] [i (in-naturals)]
                                 #:when (equal? s leader)) i)
                     0))
     (struct-copy window w [selection-set (selection-set-open (window-selection-set-name w) kept idx)])]))

;;; ---------- 视图状态 ----------

(define (check-mode who m)
  (unless (memq m '(clip wrap))
    (error who "mode 必须是 'clip 或 'wrap，得到 ~a" m)))

(define (window-set-mode w m) (check-mode 'window-set-mode m) (struct-copy window w [mode m]))
(define (window-set-top-line w n)  (struct-copy window w [top-line (max 0 n)]))
(define (window-set-top-seg w n) (struct-copy window w [top-seg (max 0 n)]))
(define (window-set-size w height width)
  (struct-copy window w [height (max 1 height)] [width (max 1 width)]))

(define (window-vscroll w delta)
  (struct-copy window w [top-line (max 0 (+ (window-top-line w) delta))]))

;; 水平滚动的参考行 = 顶行（left-col 作用于整个可见区，顶行是代表）。
(define (left-ref-text w)
  (define b (window-buffer w))
  (define n (buffer-line-count b))
  (buffer-line-ref b (max 0 (min (window-top-line w) (sub1 n)))))

;; 把显示列吸附到字符起点：落在宽字符右半会画出半格空白。
;; **不夹到行尾** —— 超过行宽的列原样保留（「滚过短行尾部」是合法状态）。
(define (snap-left-col text col)
  (if (<= col (string-display-width text))
      (snap-column-forward text col)
      col))

(define (window-set-left-col w n)
  (struct-copy window w [left-col (snap-left-col (left-ref-text w) (max 0 n))]))
(define (window-hscroll w delta)
  (window-set-left-col w (+ (window-left-col w) delta)))

;;; ---------- 点运动（纯）----------
;; 只依赖文本的四种：字符/行级。up/down 需要视口几何，见 viewport/layout.rkt。

(define (point-left b p)
  (define l (point-line p)) (define o (point-col p))
  (cond
    [(> o 0) (point l (sub1 o))]
    [(> l 0) (point (sub1 l) (string-length (buffer-line-ref b (sub1 l))))]
    [else p]))

(define (point-right b p)
  (define l (point-line p)) (define o (point-col p))
  (define n (buffer-line-count b))
  (cond
    [(< o (string-length (buffer-line-ref b l))) (point l (add1 o))]
    [(< l (sub1 n)) (point (add1 l) 0)]
    [else p]))

(define (point-home p) (point (point-line p) 0))
(define (point-end b p)
  (point (point-line p) (string-length (buffer-line-ref b (point-line p)))))

;;; ---------- 导航（每个选区各走一步）----------
;; 方向键把每个选区坍缩到 head 后移动；新位置去重/合并。

(define (window-left w)  (window-map-points w (lambda (p) (point-left  (window-buffer w) p))))
(define (window-right w) (window-map-points w (lambda (p) (point-right (window-buffer w) p))))
(define (window-home w)  (window-map-points w point-home))
(define (window-end w)   (window-map-points w (lambda (p) (point-end (window-buffer w) p))))

;;; ---------- 测试 ----------

(module+ test
  (define d (document-open "a\nb\nc\nd\ne"))
  (define b (document-buffer d))
  (define w (window-open d 2 10))

  ;; 构造：buffer 引用 + 初始光标 / 滚动 / 尺寸
  (check-equal? (window-buffer w) b)
  (check-equal? (window-point w) (point 0 0))
  (check-equal? (window-mode w) 'clip)
  (check-equal? (window-top-line w) 0)
  (check-equal? (window-top-seg w) 0)
  (check-equal? (window-height w) 2)
  (check-equal? (window-width w) 10)

  ;; 光标夹紧
  (check-equal? (window-point (window-set-point w (point 3 99))) (point 3 1))
  (check-equal? (window-point (window-set-point w (point 99 0))) (point 4 0))
  (check-equal? (window-point (window-set-document w (document-open ""))) (point 0 0))

  ;; 导航
  (check-equal? (window-point (window-right w)) (point 0 1))
  (check-equal? (window-point (window-left (window-right w))) (point 0 0))
  (check-equal? (window-point (window-left w)) (point 0 0))          ; 行首不动
  (check-equal? (window-point (window-right (window-end w))) (point 1 0))
  (check-equal? (window-point (window-left (window-right (window-end w)))) (point 0 1))
  (check-equal? (window-point (window-home (window-set-point w (point 2 0)))) (point 2 0))

  ;; 多选区：设一组，导航一次动全部
  (define ws (window-open (document-open "abcde\nfghij") 3 10))
  (define wm (window-set-selections ws (list (selection (point 0 0) (point 0 0))
                                             (selection (point 0 2) (point 0 2)))))
  (check-equal? (length (window-selections wm)) 2)
  (check-equal? (map selection-head (window-selections (window-left wm)))
                (list (point 0 0) (point 0 1)))       ; 第一不动(行首)，第二左移
  (check-equal? (length (window-selections (window-right wm))) 2)  ; 两光标各右移一格

  ;; 重叠合并 / 去重；primary 追到合并结果
  (define wo (window-set-selections ws (list (selection (point 0 0) (point 0 2))
                                             (selection (point 0 1) (point 0 3)))))
  (check-equal? (length (window-selections wo)) 1)
  (check-equal? (call-with-values (lambda () (selection-range (car (window-selections wo)))) list)
                (list (point 0 0) (point 0 3)))

  ;; primary 边界不歧义：[0,2) 与 caret(2) 并存时 primary=caret；首尾相接的两个区间取后者
  (check-equal? (window-primary (window-set-selections ws (list (selection (point 0 0) (point 0 2))
                                                                (caret (point 0 2))) 1))
                (caret (point 0 2)))
  (check-equal? (window-primary (window-set-selections ws (list (selection (point 0 0) (point 0 2))
                                                                (selection (point 0 2) (point 0 4))) 1))
                (selection (point 0 2) (point 0 4)))

  ;; 滚动 / 尺寸
  (check-equal? (window-top-line (window-vscroll w 2)) 2)
  (check-equal? (window-top-line (window-vscroll w -5)) 0)
  (check-equal? (window-top-line (window-set-top-line w 4)) 4)
  (check-equal? (window-left-col (window-hscroll (window-set-left-col w 3) 2)) 5)
  (check-equal? (window-set-size w 30 100) (window-set-size w 30 100))
  (check-equal? (window-mode (window-set-mode w 'wrap)) 'wrap)
  (check-equal? (window-top-seg (window-set-top-seg w 3)) 3)

  ;; 水平吸附：宽字符右半 → 下一字符起点；滚过行尾保留
  (define wd (window-open (document-open "中abc") 2 4))
  (check-equal? (window-left-col (window-set-left-col wd 0)) 0)
  (check-equal? (window-left-col (window-set-left-col wd 1)) 2)
  (check-equal? (window-left-col (window-set-left-col wd 2)) 2)
  (check-equal? (window-left-col (window-set-left-col wd 99)) 99)

  ;; 未知 mode → 报错
  (check-exn exn:fail? (lambda () (window-set-mode w 'bad)))

  ;; —— 点运动原语 ——
  (define bp (buffer-open "ab\ncd"))
  (check-equal? (point-right bp (point 0 1)) (point 0 2))
  (check-equal? (point-right bp (point 0 2)) (point 1 0))
  (check-equal? (point-left bp (point 1 0)) (point 0 2))
  (check-equal? (point-home (point 1 1)) (point 1 0))
  (check-equal? (point-end bp (point 0 0)) (point 0 2))

  ;; —— 显式 primary + map 算子 ——
  (define wp0 (window-set-selections ws (list (caret (point 0 0)) (caret (point 0 2))) 1))
  (check-equal? (window-primary wp0) (caret (point 0 2)))
  (check-equal? (window-primary-index wp0) 1)
  (check-true (window-selection-member? wp0 (caret (point 0 0))))
  ;; map 全部（两端移动）；primary 保持
  (define wp1 (window-map-selections wp0
                 (lambda (s) (selection-map-both (lambda (p) (point-right (window-buffer wp0) p)) s))))
  (check-equal? (map selection-head (window-selections wp1)) (list (point 0 1) (point 0 3)))
  (check-equal? (window-primary wp1) (caret (point 0 3)))
  ;; map primary：只动主选区，其余不动
  (define wp2 (window-map-primary wp0
                 (lambda (s) (selection-map-head (lambda (p) (point-right (window-buffer wp0) p)) s))))
  (check-equal? (selection-head (list-ref (window-selections wp2) 0)) (point 0 0))
  (check-equal? (selection-head (window-primary wp2)) (point 0 3))
  ;; 增 / 删 / 设 primary
  (check-equal? (length (window-selections (window-add-selection wp0 (caret (point 0 4))))) 3)
  (check-equal? (window-primary (window-add-selection wp0 (caret (point 0 4)) #:primary? #t)) (caret (point 0 4)))
  (check-equal? (length (window-selections (window-remove-selection wp0 (caret (point 0 0))))) 1)
  (check-equal? (window-primary (window-set-primary wp0 (caret (point 0 0)))) (caret (point 0 0)))

  ;; 名字（命名区间组）：设组 / 读名 / 清除；map 保留名字
  (define wg (window-set-selection-set w (selection-set-open 'g (list (caret (point 0 0)) (caret (point 0 2))) 0)))
  (check-equal? (window-selection-set-name wg) 'g)
  (check-equal? (window-selection-set-name (window-map-points wg (lambda (p) p))) 'g)
  (check-equal? (window-selection-set-name (window-set-point wg (point 0 1))) #f)
  (define wgc (window-clear-selection-set wg))
  (check-false (window-selection-set-name wgc))
  (check-equal? (length (window-selections wgc)) 1)
  (check-equal? (window-primary wgc) (caret (point 0 0)))

  (displayln "window.rkt: all tests passed"))
