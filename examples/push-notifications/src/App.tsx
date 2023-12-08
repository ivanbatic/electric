import logo from './logo.svg'
import './App.css'
import './style.css'

import { ElectricWrapper } from './ElectricWrapper'
import { UserPicker } from './UserPicker'

export default function App() {

  return (
    <div className="App">
      <header className="App-header">
        <img src={logo.toString()} className="App-logo" alt="logo" />
        <ElectricWrapper>
          <UserPicker />
        </ElectricWrapper>
      </header>
    </div>
  );
}