import 'animate.css/animate.min.css'
import Board from './pages/Board'
import { useEffect, useState, createContext } from 'react'
import { Route, Routes, BrowserRouter } from 'react-router-dom'
import { cssTransition, ToastContainer } from 'react-toastify'
import 'react-toastify/dist/ReactToastify.css'
import List from './pages/List'
import Issue from './pages/Issue'
import LeftMenu from './components/LeftMenu'

import { ElectricProvider, initElectric } from './electric'
import { Electric } from './generated/client'

interface MenuContextInterface {
  showMenu: boolean
  setShowMenu: (show: boolean) => void
}

export const MenuContext = createContext(null as MenuContextInterface | null)

const slideUp = cssTransition({
  enter: 'animate__animated animate__slideInUp',
  exit: 'animate__animated animate__slideOutDown',
})

const App = () => {
  const [electric, setElectric] = useState<Electric>()
  const [showMenu, setShowMenu] = useState(false)

  useEffect(() => {
    const init = async () => {
      const client = await initElectric()
      setElectric(client)
      const { synced } = await client.db.issue.sync({
        include: {
          comment: true,
        },
      })
      await synced
    }

    init()
  }, [])

  if (electric === undefined) {
    return null
  }

  const router = (
    <Routes>
      <Route path="/" element={<List />} />
      <Route path="/active" element={<List title="Active Issues" />} />
      <Route path="/backlog" element={<List title="Backlog" />} />
      <Route path="/board" element={<Board />} />
      <Route path="/issue/:id" element={<Issue />} />
    </Routes>
  )

  return (
    <ElectricProvider db={electric}>
      <MenuContext.Provider value={{ showMenu, setShowMenu }}>
        <BrowserRouter>
          <div className="flex w-full h-screen overflow-y-hidden">
            <LeftMenu />
            {router}
          </div>
          <ToastContainer
            position="bottom-right"
            autoClose={5000}
            hideProgressBar
            newestOnTop
            closeOnClick
            rtl={false}
            transition={slideUp}
            pauseOnFocusLoss
            draggable
            pauseOnHover
          />
        </BrowserRouter>
      </MenuContext.Provider>
    </ElectricProvider>
  )
}

export default App